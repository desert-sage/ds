% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_behave -- the corpus's behavioural fixtures, compiled by this compiler
% and run in the Mercury runtime.
%
% `specs/conformance/{adapter,cross-tier,logical,runtime,temporal}/*.json`: a
% DS source, a list of steps and an expectation about what the engine does,
% every category but `compiler`, which `test_conformance` judges.
%
% `test_conformance`'s rules hold: every indexed fixture must open and parse,
% and every fixture must pass or be deprecated, or the gate fails.
%
% The expectation semantics are `runner.py`'s, kind by kind:
%
%   * `rule_fire_order` -- the rule names of every `rule_fire_begin`, in order,
%     equal `expected_rule_names`;
%   * `log_message_sequence` -- the messages of every `action_log`, in order,
%     equal `expected_messages`;
%   * `runtime_fact_count` -- after `asserts`, `generate_asserts` and an
%     optional pump, the live fact count equals `fact_count_after`; with
%     `add_compiled_code`, on an artefact given CompiledCode atoms to skip
%     first (`compiled_code_added`);
%   * `event_sequence` -- the stream's event kinds, cut down to the kinds
%     `expected_kinds` names, ARE `expected_kinds` ([RCTS.1.2.10]): other
%     kinds interleave, and every event of a named kind is stated;
%     `event_sequence_strict` -- it IS the stream's kinds;
%     `event_kinds_forbidden` -- none of `forbidden_kinds` appears;
%   * `temporal_sequence` -- the steps on a mock clock from 0, then the live
%     fact count equals `fact_count_after`;
%   * `event_seq_monotonic` -- over every stream event, or a `filter_kind` view
%     of them, `seq` strictly increases, there are at least `min_events`,
%     consecutive `seq`s differ by any `expected_seq_step`, and the first
%     `clock_ns` values equal any `expected_clocks`. `seq` is `ds.effect`'s
%     recorder numbering and `clock_ns` the engine clock after each step;
%   * `introspection_assert` -- after the steps, each of `checks` holds: the
%     live fact count, a fact's justifier rules or their count, lower
%     bounds on the Rete network's nodes and edges, or the schema a slot
%     names as its reference; with `add_schema_ref`, on an artefact whose
%     Slot was given a `schema_ref` first (`schema_ref_added`);
%   * `hash_order_independence` -- the same asserts in each of `orders`, on
%     fresh engines, give the same rule-fire order and fact count, and the
%     first matches any `expected_fire_order`;
%   * `replay_determinism` -- the run is encoded to RFCS, decoded, and replayed
%     into a fresh engine, which reproduces its events and final clock;
%   * `clone_determinism` -- `steps`, then `after_clone` run twice from the
%     same engine, whose two streams must agree and carry `min_events` events
%     and `min_rule_fires` fires, then `after_free` on one of them, which
%     must fire `min_rule_fires_after_free` (see `run_clone_determinism`);
%   * `rfcs_roundtrip` -- the run's RFCS recording, with an unknown atom
%     spliced in, decodes; StreamHeader leads, a SchemaDef precedes the first
%     FactAssert, the header round-trips, and the known atoms equal
%     `expected_atoms`;
%   * `rfcs_artefact_strip` -- the recording decoded without the artefact
%     gives every FactAssert's id, seq, schema name and slots as asserted;
%   * `pbf_framing` -- `PBF_FRAMING_VECTORS.json`'s encode, band and decode
%     groups through `ds.atom` / `ds.wire`, without the protobuf legs;
%   * `runtime_error` -- after `asserts` and an optional pump, or `steps`, a
%     fault was raised whose `libds.h` code is `code` and whose text contains
%     any `message_contains` (see `run_runtime_error` for what "text" is
%     here), and, with `fault_at`, by exactly that input;
%   * `header_field_eq` -- after the steps, each of `checks` holds of the
%     session header pyds reports (see `header_result`);
%   * `adapter_mock` -- the steps, then every call to a mocked service
%     answered with its response fact and pumped, to a fixed point; then the
%     log messages, call count and fact count, as named (see
%     `run_adapter_mock`);
%   * `cross_tier_fact_counts` / `cross_tier_per_engine_event_counts` -- one
%     engine per `expect.engines` entry, the steps routed by `engine` and
%     `forward` carrying publications across, then each engine's fact count,
%     or its count of each event kind, as named (see `run_cross_tier`).
%
% An event's kind is the name `pyds` gives it (`pyds_event_to_dict`):
% `se_log_emitted` is `action_log`, `se_clock_tick` is `tick`, and so on.
% `se_fact_withdraw` is `fact_retract` too, as libds delivers an engine and a
% host removal on one callback kind ([RFCS.7a]). An engine error is named for
% its class: `computation_error`, `bounds_error`, `type_error` or
% `engine_error`.
%
% The logical kinds run on a mock clock set to 0 before the steps. A kind this
% driver does not evaluate is a `fail` ([RCTS.1.2.7]); the two kinds about an
% unregistered callback fail with a detail of their own.
%
% A pass is also judged on its rule firings ([RCTS.1.2.17]): see
% `dead_rules_result`.
%
% A compile refused only with `DS_VALIDATE_RULE_NOT_LOWERED` is `unlowered`,
% named with its reason, not `rejected`.
%-----------------------------------------------------------------------------%

:- module test_behave.
:- interface.

:- import_module io.

    % (passed, failed) over the gate's checks. The corpus census is printed.
    %
:- pred run(int::out, int::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.
:- import_module ds.action.
:- import_module ds.atom.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.effect.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fact.
:- import_module ds.fact_external.
:- import_module ds.fact_receive.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.json.
    % Used, not imported: its `parsed` / `refused` constructors would overload
    % this module's `refused` (`refusal`). Only `jr_int_outside_int64` and
    % `jr_float_outside_double` are read.
:- use_module ds.json_text.
:- import_module ds.network.
:- import_module ds.replay.
:- import_module ds.rfcs.
:- import_module ds.schema.
:- import_module ds.sha256.
:- import_module ds.tms.
:- import_module ds.value.
:- import_module ds.wire.
:- import_module ds.version.

:- import_module dsc.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.dialect.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.imports.
:- import_module dsc.json.

:- import_module field_order_walk.
:- import_module test_conformance.

:- import_module assoc_list.
:- import_module bitmap.
:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint32.
:- import_module uint64.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type outcome
    --->    bo_pass
            % The expectation held.
    ;       bo_fail
            % It ran and the expectation did not hold.
    ;       bo_deprecated
    ;       bo_stopped
            % The front end refused it.
    ;       bo_rejected
            % `resolve` / `validate` refused it.
    ;       bo_unlowered
            % Refused, and only with `DS_VALIDATE_RULE_NOT_LOWERED`.
    ;       bo_load_failed
            % Compiled and lowered, and the runtime's loader refused it.
    ;       bo_unsupported.
            % A step or slot shape this driver does not model.

:- func outcome_name(outcome) = string.

outcome_name(bo_pass) = "pass".
outcome_name(bo_fail) = "fail".
outcome_name(bo_deprecated) = "deprecated".
outcome_name(bo_stopped) = "stopped".
outcome_name(bo_rejected) = "rejected".
outcome_name(bo_unlowered) = "unlowered".
outcome_name(bo_load_failed) = "load-failed".
outcome_name(bo_unsupported) = "unsupported".

:- func all_outcomes = list(outcome).

all_outcomes = [bo_pass, bo_fail, bo_deprecated, bo_stopped, bo_rejected,
    bo_unlowered, bo_load_failed, bo_unsupported].

    % The detail of a fixture whose kind this driver does not evaluate. One
    % string, so the report can find those failures again among the others.
    %
:- func unevaluated_kind = string.

unevaluated_kind =
    "this driver does not evaluate the expectation kind ([RCTS.1.2.7])".

    % The detail of a fixture whose kind is about an unregistered integrator
    % callback. This runtime's pump returns its effects as one list
    % (MERCURY.md §16.2), so the kind is a binding's to judge. A `fail`
    % ([RCTS.1.2.7]), with a detail of its own.
    %
:- func no_callback_kind = string.

no_callback_kind =
    "this runtime has no integrator callback to leave unregistered: its pump "
    ++ "returns its effects; a binding's kind, failed per [RCTS.1.2.7]".

:- pred callback_kind(string::in) is semidet.

callback_kind("adapter_essential_null_cb_error").
callback_kind("adapter_cache_volatile_no_cb").

    % One fixture's outcome, its kind, and what makes a non-pass triageable:
    % the want/got of a failure, the reason a rule went unlowered, the code a
    % refusal carried.
    %
:- type behave_result
    --->    behave_result(
                br_outcome :: outcome,
                br_kind    :: string,
                br_detail  :: string
            ).

    % A fixture's result.
    %
:- type fixture_row
    --->    fixture_row(
                fr_result :: behave_result
            ).

:- type tally
    --->    tally(t_pass :: int, t_fail :: int).

:- pred check(string::in, bool::in, tally::in, tally::out, io::di, io::uo)
    is det.

check(Name, Ok, !Tally, !IO) :-
    (
        Ok = yes,
        !Tally ^ t_pass := !.Tally ^ t_pass + 1
    ;
        Ok = no,
        !Tally ^ t_fail := !.Tally ^ t_fail + 1,
        io.format("  FAIL  %s\n", [s(Name)], !IO)
    ).

%-----------------------------------------------------------------------------%

run(Pass, Fail, !IO) :-
    io.read_named_file_as_string("behaviour-index.txt", IndexRes, !IO),
    (
        IndexRes = error(_),
        check("behaviour-index.txt is present and readable", no,
            tally(0, 0), T, !IO)
    ;
        IndexRes = ok(IndexText),
        Names = list.filter(non_empty,
            list.map(string.strip, string.split_at_char('\n', IndexText))),
        % The harness's dialects, as `test_conformance` registers them; a
        % file that does not register fails that suite's gate, not this one's.
        harness_registry(Registry, _, !IO),
        read_stdlib(Stdlib, !IO),
        list.map_foldl(run_fixture(Registry, Stdlib), Names, Results, !IO),
        % [RCTS.1.2.14]: no standard library fails the run, not each fixture.
        check("RCTS.1.2.14:the standard library is read (DSC_STDLIB)",
            ( if stdlib_is_read(Stdlib) then yes else no ),
            tally(0, 0), T0, !IO),
        report(Names, Results, T0, T1, !IO),
        dead_rules_checks(T1, T2, !IO),
        splice_field_checks(T2, T3, !IO),
        tamper_checks(T3, T4, !IO),
        recording_fields_checks(T4, T5, !IO),
        kind_fields_checks(T5, T5a, !IO),
        timetag_checks(T5a, T6, !IO),
        expr_shape_checks(T6, T7, !IO),
        step_vocabulary_checks(Registry, Stdlib, T7, T8, !IO),
        stream_edit_checks(T8, T9, !IO),
        category_checks(T9, T, !IO)
    ),
    Pass = T ^ t_pass,
    Fail = T ^ t_fail.

:- pred non_empty(string::in) is semidet.

non_empty(S) :- S \= "".

    % [RCTS.1.2.3]'s refusal, as `run_fixture` and `test_conformance` make
    % it: each case it must refuse, with `runner.py`'s texts, and the six
    % directories it must admit.
    %
:- pred category_checks(tally::in, tally::out, io::di, io::uo) is det.

category_checks(!T, !IO) :-
    Of = (func(C) = j_object(object(["category" - C]))),
    check("RCTS.1.2.3:a fixture whose category is its directory is admitted",
        ( if
            list.all_true(
                (pred(D::in) is semidet :-
                    rcts_1_2_3_refusal(D, Of(j_string(D))) = no),
                ["adapter", "compiler", "cross-tier", "logical", "runtime",
                 "temporal"])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.3:a category that is not its directory is refused",
        ( if rcts_1_2_3_refusal("runtime", Of(j_string("logical")))
                = yes("`category` is `logical`, and the fixture is in "
                    ++ "`runtime/`")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.3:a directory that is no category is refused",
        ( if rcts_1_2_3_refusal("logicl", Of(j_string("logicl")))
                = yes("the fixture is in `logicl/`, which is no category of "
                    ++ "[RCTS.1.1.4]")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.3:a category that is not a string is refused",
        ( if rcts_1_2_3_refusal("logical", Of(j_int(7i64)))
                = yes("`category` is not a string")
          then yes else no ), !T, !IO).

:- pred run_fixture(registry::in, stdlib::in, string::in,
                    maybe(fixture_row)::out, io::di, io::uo) is det.

run_fixture(Registry, Stdlib, Name, Result, !IO) :-
    io.read_named_file_as_string("behaviour/" ++ Name, Res, !IO),
    (
        Res = error(_),
        Result = no
    ;
        Res = ok(Text),
        % The repeats are kept for the format check ([RCTS.1.2.1]); the term
        % holds only the last value of each.
        rcts_1_2_1_parse_corpus_json(Text, ParsedRaw, Repeats),
        ( if ParsedRaw = json_ok(Raw) then
            Parsed0 = json_ok(expand_repeats(Raw))
        else
            Parsed0 = ParsedRaw
        ),
        attach_staged("pbf_framing", "PBF_FRAMING_VECTORS.json", "corpus",
            Parsed0, Parsed1, !IO),
        attach_staged("field_order", "FIELD_ORDER_TABLE.json", "table",
            Parsed1, Parsed, !IO),
        (
            Parsed = json_ok(Fixture),
            % [RCTS.1.2.3]: the index names each fixture `<directory>/<file>`.
            % A retired fixture is judged by nothing here (`classify`), as
            % `runner.py` skips it before its format.
            ( if
                not (
                    Fixture = j_object(FixtureMs),
                    lookup_member(FixtureMs, "deprecated", _)
                ),
                string.split_at_char('/', Name) = [Dir | _],
                rcts_1_2_3_refusal(Dir, Fixture) = yes(Why)
            then
                Result = yes(fixture_row(behave_result(bo_fail, "",
                    "malformed fixture: [RCTS.1.2.3] " ++ Why)))
            else if classify(Registry, Stdlib, Repeats, Fixture, Classified)
            then
                Result = yes(fixture_row(Classified))
            else
                Result = no,
                % [RCTS.1.2.15]: the refusal names the clause it is under.
                rcts_fixture_format(Stdlib, Repeats, Fixture, Format),
                (
                    Format = malformed(_, _),
                    io.format("    malformed fixture %s: %s\n",
                        [s(Name), s(malformed_text(Format))], !IO)
                ;
                    Format = well_formed(_)
                )
            )
        ;
            Parsed = json_error(_, _),
            Result = no
        )
    ).

    % A fixture's `{"$repeat": "<text>", "count": N}`, anywhere in it, as the
    % text repeated N times: `runner.py`'s `_expand_repeats`. An object with
    % exactly those two members is the form; nothing else is touched.
    %
:- func expand_repeats(json) = json.

expand_repeats(J) = Out :-
    ( if
        J = j_object(Obj),
        list.length(members(Obj)) = 2,
        lookup_member(Obj, "$repeat", j_string(Text)),
        lookup_member(Obj, "count", j_int(N)),
        N >= 0i64
    then
        Out = j_string(string.append_list(
            list.duplicate(int64.cast_to_int(N), Text)))
    else if J = j_object(Obj) then
        Out = j_object(object(list.map(
            (func(K - V) = K - expand_repeats(V)), members(Obj))))
    else if J = j_array(Js) then
        Out = j_array(list.map(expand_repeats, Js))
    else
        Out = J
    ).

    % Two kinds read a JSON file the gate stages beside the corpus, in
    % `behaviour/`: a `pbf_framing` fixture's bytes are in
    % `PBF_FRAMING_VECTORS.json` (attached as `corpus`), and a `field_order`
    % fixture walks a recording by the field table `field_order.py --table`
    % writes from `proto/` (`FIELD_ORDER_TABLE.json`, attached as `table`).
    % Attached here, where there is IO. A fixture of any other kind passes
    % through untouched, and so does one whose file is missing, which the
    % check then reports absent.
    %
:- pred attach_staged(string::in, string::in, string::in,
    json_parse_result::in, json_parse_result::out, io::di, io::uo) is det.

attach_staged(Kind, File, Member, Parsed0, Parsed, !IO) :-
    ( if
        Parsed0 = json_ok(j_object(Ms)),
        lookup_member(Ms, "expect", EJ), EJ = j_object(EMs),
        lookup_member(EMs, "kind", KJ), KJ = j_string(Kind)
    then
        io.read_named_file_as_string("behaviour/" ++ File, CRes, !IO),
        ( if
            CRes = ok(CText),
            parse_json(CText, CParsed),
            CParsed = json_ok(Corpus)
        then
            Expect = j_object(object(members(EMs) ++ [Member - Corpus])),
            Parsed = json_ok(j_object(object(list.map(
                (func(K - J) = K - ( if K = "expect" then Expect else J )),
                members(Ms)))))
        else
            Parsed = Parsed0
        )
    else
        Parsed = Parsed0
    ).

    % Fails when the fixture is malformed: the format check refused it
    % ([RCTS.1.2.15]), or its kind lacks a field it needs. A
    % `malformed_fixture` is judged on the format check alone.
    %
:- pred classify(registry::in, stdlib::in, list(string)::in, json::in,
                 behave_result::out) is semidet.

classify(Registry, Stdlib, Repeats, Fixture, Result) :-
    Fixture = j_object(Members),
    ( if lookup_member(Members, "deprecated", _) then
        Result = behave_result(bo_deprecated, "", "")
    else
        lookup_member(Members, "expect", ExpectJ),
        ExpectJ = j_object(Expect),
        lookup_member(Expect, "kind", KindJ),
        KindJ = j_string(Kind),
        rcts_fixture_format(Stdlib, Repeats, Fixture, Format),
        ( if Kind = "malformed_fixture" then
            lookup_member(Expect, "reason", ReasonJ),
            ReasonJ = j_string(Reason),
            Result = malformed_fixture_result(Reason, Format)
        else if cross_tier_kind(Kind) then
            Format = well_formed(Libraries),
            % One program per `expect.engines` entry, not the top-level
            % `rules_ds`, which a cross-tier fixture leaves empty.
            Result = steps_placed(Members, Expect, Kind,
                kind_fields_placed(Kind, Expect,
                recording_fields_placed(Kind, Expect,
                tamper_placed(Kind, Expect, splice_field_placed(Kind,
                Expect, timetag_offset_placed(Kind, Expect,
                replay_cache_cap_placed(Kind, Expect,
                dead_rules_result(Members, no,
                    run_cross_tier(Registry, Kind, Libraries, Expect)))))))))
        else if supported_kind(Kind) then
            Format = well_formed(Libraries),
            lookup_member(Members, "rules_ds", SourceJ),
            SourceJ = j_string(Source),
            % A fixture with no `use` line compiles as though it began with
            % `use default` ([LDIA.2.10.1]).
            compile_labelled_in(Registry, as_though("default"),
                Libraries, dsrt_absent, in_memory_labels,
                Source, Compiled),
            {Result0, Fired} = judge_run(Kind, Expect, Compiled),
            Result = steps_placed(Members, Expect, Kind,
                kind_fields_placed(Kind, Expect,
                recording_fields_placed(Kind, Expect,
                tamper_placed(Kind, Expect, splice_field_placed(Kind,
                Expect, timetag_offset_placed(Kind, Expect,
                replay_cache_cap_placed(Kind, Expect,
                dead_rules_result(Members, Fired, Result0))))))))
        else if callback_kind(Kind) then
            Format = well_formed(_),
            Result = behave_result(bo_fail, Kind, no_callback_kind)
        else
            Format = well_formed(_),
            Result = behave_result(bo_fail, Kind, unevaluated_kind)
        )
    ).

    % [RCTS.1.2.15]: the fixture passes only when the format check refuses it
    % under the clause `expect.reason` names.
    %
:- func malformed_fixture_result(string, fixture_format) = behave_result.

malformed_fixture_result(Reason, Format) = Result :-
    Kind = "malformed_fixture",
    (
        Format = well_formed(_),
        Result = behave_result(bo_fail, Kind,
            "want a refusal under [" ++ Reason ++ "], got none")
    ;
        Format = malformed(Clause, _),
        ( if Clause = Reason then
            Result = behave_result(bo_pass, Kind, "")
        else
            Result = behave_result(bo_fail, Kind,
                "want a refusal under [" ++ Reason ++ "], got "
                ++ malformed_text(Format))
        )
    ).

:- pred supported_kind(string::in) is semidet.

supported_kind("rule_fire_order").
supported_kind("log_message_sequence").
supported_kind("runtime_fact_count").
supported_kind("event_sequence").
supported_kind("event_sequence_strict").
supported_kind("event_kinds_forbidden").
supported_kind("temporal_sequence").
supported_kind("event_seq_monotonic").
supported_kind("introspection_assert").
supported_kind("hash_order_independence").
supported_kind("replay_determinism").
supported_kind("replay_refused").
supported_kind("field_order").
supported_kind("clone_determinism").
supported_kind("rfcs_roundtrip").
supported_kind("rfcs_artefact_strip").
supported_kind("pbf_framing").
supported_kind("runtime_error").
supported_kind("adapter_calls").
supported_kind("adapter_cache_sets").
supported_kind("adapter_cache_deletes").
supported_kind("header_field_eq").
supported_kind("adapter_mock").

    % The kinds whose run records every rule that fires, so that
    % [RCTS.1.2.17] judges their firings: `runner.py`'s drivers that keep a
    % coverage record (`_coverage_artefact`).
    %
:- pred records_firings(string::in) is semidet.

records_firings("runtime_fact_count").
records_firings("temporal_sequence").
records_firings("adapter_calls").
records_firings("adapter_cache_sets").
records_firings("adapter_cache_deletes").
records_firings("adapter_mock").
records_firings("event_sequence").
records_firings("event_sequence_strict").
records_firings("event_seq_monotonic").
records_firings("event_kinds_forbidden").
records_firings("rule_fire_order").
records_firings("log_message_sequence").
records_firings("header_field_eq").
records_firings("introspection_assert").

    % [RCTS.1.2.17], as `runner.py`'s `_dead_rules_refusal` applies it, to a
    % fixture whose kind passed: a name in `dead_rules_expected` that is no rule
    % of `rules_ds` fails it; where the run recorded its firings (`yes`), a
    % listed rule that fired fails it, and so does a rule the list does not name
    % that never fired; where it recorded none (`no`), a non-empty list fails
    % it. Any other outcome stands.
    %
:- func dead_rules_result(json_members, maybe(list(string)), behave_result)
    = behave_result.

dead_rules_result(Members, Fired, Result0) = Result :-
    Kind = Result0 ^ br_kind,
    Listed = string_array(array_member(Members, "dead_rules_expected")),
    Defined = ( if lookup_member(Members, "rules_ds", j_string(Source)) then
                    source_rule_names(Source)
                else
                    [] ),
    Unknown = list.sort_and_remove_dups(list.filter(
        (pred(N::in) is semidet :- not list.member(N, Defined)), Listed)),
    ( if Result0 ^ br_outcome \= bo_pass then
        Result = Result0
    else if Unknown = [_ | _] then
        Result = behave_result(bo_fail, Kind,
            "dead_rules_expected names no rule of this fixture: "
                ++ string.join_list(", ", Unknown))
    else
        (
            Fired = no,
            (
                Listed = [],
                Result = Result0
            ;
                Listed = [_ | _],
                Result = behave_result(bo_fail, Kind,
                    "dead_rules_expected is declared, and the `" ++ Kind
                        ++ "` driver records no rule firings, so it cannot "
                        ++ "be checked")
            )
        ;
            Fired = yes(Names),
            FiredListed = list.sort_and_remove_dups(list.filter(
                (pred(N::in) is semidet :- list.member(N, Names)), Listed)),
            Undeclared = list.filter(
                (pred(N::in) is semidet :-
                    not list.member(N, Names),
                    not list.member(N, Listed)),
                Defined),
            ( if FiredListed = [_ | _] then
                Result = behave_result(bo_fail, Kind,
                    string.format("dead_rules_expected: %s fired "
                        ++ "(%d firing(s) in the run)",
                        [s(string.join_list(", ", FiredListed)),
                         i(list.length(Names))]))
            else if Undeclared = [_ | _] then
                Result = behave_result(bo_fail, Kind,
                    "rule(s) never fired and not in dead_rules_expected: "
                        ++ string.join_list(", ", Undeclared))
            else
                Result = Result0
            )
        )
    ).

    % The names of the rules `rules_ds` declares, in order: every line that
    % opens `rule <name>`, the name `[a-z][A-Za-z0-9_]*`. `runner.py`'s
    % `_RULE_NAME_RE`, so the two harnesses judge the same set.
    %
:- func source_rule_names(string) = list(string).

source_rule_names(Source) =
    list.filter_map(line_rule_name, string.split_at_char('\n', Source)).

:- func line_rule_name(string) = string is semidet.

line_rule_name(Line) = Name :-
    string.remove_prefix("rule", Line, Rest),
    string.index(Rest, 0, Sep),
    char.is_whitespace(Sep),
    Trimmed = string.lstrip(Rest),
    string.index(Trimmed, 0, First),
    char.is_lower(First),
    Name = string.left(Trimmed,
        string.prefix_length(is_rule_name_char, Trimmed)).

:- pred is_rule_name_char(char::in) is semidet.

is_rule_name_char(C) :-
    ( char.is_alnum(C)
    ; C = '_'
    ).

    % `dead_rules_result`'s cases, run on every build: `test_conformance.py`'s
    % `test_rcts_1_2_17__*`, over a two-rule program whose `quiet` never
    % fires.
    % @spec [RCTS.1.2.17]
    %
:- pred dead_rules_checks(tally::in, tally::out, io::di, io::uo) is det.

dead_rules_checks(!T, !IO) :-
    Source = "schema T scope logical:\n    v: Int key\n\n"
        ++ "rule fires:\n    T\n->\n    log info \"a\"\n\n"
        ++ "rule quiet:\n    T t where t.v > 9\n->\n    log info \"b\"\n",
    Fixture = (func(Listed) = object(["rules_ds" - j_string(Source)]
        ++ ( if Listed = [] then []
             else ["dead_rules_expected"
                - j_array(list.map(func(N) = j_string(N), Listed))] ))),
    Passed = behave_result(bo_pass, "rule_fire_order", ""),
    Outcome = (func(Listed, Fired) =
        dead_rules_result(Fixture(Listed), Fired, Passed) ^ br_outcome),
    check("RCTS.1.2.17: the rules of `rules_ds` are read from its source",
        ( if source_rule_names(Source) = ["fires", "quiet"] then yes
          else no ), !T, !IO),
    check("RCTS.1.2.17: a listed rule that stays dead passes",
        ( if Outcome(["quiet"], yes(["fires"])) = bo_pass then yes else no ),
        !T, !IO),
    check("RCTS.1.2.17: a listed rule that fires fails",
        ( if Outcome(["quiet"], yes(["fires", "quiet"])) = bo_fail then yes
          else no ), !T, !IO),
    check("RCTS.1.2.17: a listed name that is no rule fails",
        ( if Outcome(["quiett"], yes(["fires"])) = bo_fail then yes else no ),
        !T, !IO),
    check("RCTS.1.2.17: a list on a kind that records no firings fails",
        ( if Outcome(["quiet"], no) = bo_fail then yes else no ), !T, !IO),
    check("RCTS.1.2.17: an unlisted rule that never fires fails",
        ( if Outcome([], yes(["fires"])) = bo_fail then yes else no ),
        !T, !IO),
    check("RCTS.1.2.17: every rule firing needs no list",
        ( if Outcome([], yes(["fires", "quiet"])) = bo_pass then yes
          else no ), !T, !IO),
    check("RCTS.1.2.17: no list on a kind that records no firings is not "
            ++ "judged",
        ( if Outcome([], no) = bo_pass then yes else no ), !T, !IO),
    check("RCTS.1.2.17: a kind that did not pass keeps its own outcome",
        ( if
            dead_rules_result(Fixture(["quiett"]), yes([]),
                behave_result(bo_unsupported, "rule_fire_order", "x"))
                ^ br_outcome = bo_unsupported
          then yes else no ), !T, !IO).

%-----------------------------------------------------------------------------%

:- func judge(string, json_members, compile_result) = behave_result.

judge(Kind, Expect, Compiled) = Result :-
    {Result, _} = judge_run(Kind, Expect, Compiled).

    % `judge`, with the names of the rules the run fired, in order, where the
    % kind records them (`records_firings`), and `no` where it does not.
    %
:- func judge_run(string, json_members, compile_result)
    = {behave_result, maybe(list(string))}.

judge_run(Kind, _, compile_stopped(_, Message, _, _)) =
    {behave_result(bo_stopped, Kind, Message), no}.
judge_run(Kind, _, compile_rejected(Diagnostics)) = {Result, no} :-
    ( if
        Diagnostics = [First | _],
        list.all_true(
            ( pred(D::in) is semidet :-
                D ^ dg_code = dc_validate(dv_rule_not_lowered)
            ), Diagnostics)
    then
        Result = behave_result(bo_unlowered, Kind, First ^ dg_message)
    else
        Result = behave_result(bo_rejected, Kind, string.join_list(" ",
            list.sort_and_remove_dups(
                list.map(func(D) = code_name(D ^ dg_code), Diagnostics))))
    ).
judge_run(Kind, Expect, compiled(Bytes, _, _)) = Judged :-
    ( if
        lookup_member(Expect, "tamper", TamperJ),
        ( Kind = "runtime_error" ; Kind = "replay_determinism" ),
        TamperJ = j_object(TamperO),
        members(TamperO) = ["drop_call_operand" - RuleJ]
    then
        % The one member whose artefact loads ([RDSC.4a.9.3]): its fault is a
        % step's, so the edited artefact goes to the steps. On
        % `replay_determinism` both the recording and the replaying engine
        % run the edited program.
        ( if
            RuleJ = j_string(Rule),
            call_operand_dropped(Bytes, Rule, Edited)
        then
            Judged = judge_loaded(Kind, Expect, Edited)
        else
            Judged = {behave_result(bo_fail, Kind,
                "tamper `" ++ string.string(TamperJ)
                    ++ "` is no member of [RCTS.1.2.21]'s set, or has no "
                    ++ "site in this artefact"), no}
        )
    else if
        Kind = "runtime_fact_count",
        lookup_member(Expect, "tamper", TamperJ)
    then
        % [RCTS.1.2.21]: the structural edits, made before
        % `add_compiled_code`'s. A refused load fails the fixture in
        % `judge_loaded`, as `runner.py` fails it.
        ( if fact_count_edited(Expect, Bytes, Edited) then
            Judged = judge_loaded(Kind, Expect, Edited)
        else
            Judged = {behave_result(bo_fail, Kind,
                "tamper `" ++ string.string(TamperJ)
                    ++ "` is no member of [RCTS.1.2.21]'s set, or it or "
                    ++ "add_compiled_code has no site in this artefact"), no}
        )
    else if lookup_member(Expect, "tamper", TamperJ) then
        Judged = {judge_tampered(Kind, Expect, TamperJ, Bytes), no}
    else if lookup_member(Expect, "add_schema_ref", EditJ) then
        ( if schema_ref_added(EditJ, Bytes, Edited) then
            Judged = judge_loaded(Kind, Expect, Edited)
        else
            Judged = {behave_result(bo_fail, Kind,
                "add_schema_ref `" ++ string.string(EditJ)
                    ++ "` has no site in this artefact"), no}
        )
    else if lookup_member(Expect, "add_compiled_code", CodeJ) then
        ( if compiled_code_added(CodeJ, Bytes, Edited) then
            Judged = judge_loaded(Kind, Expect, Edited)
        else
            Judged = {behave_result(bo_fail, Kind,
                "add_compiled_code `" ++ string.string(CodeJ)
                    ++ "` has no site in this artefact ([RCTS.1.2.31])"), no}
        )
    else
        Judged = judge_loaded(Kind, Expect, Bytes)
    ).

    % `runtime_fact_count`'s artefact, edited as `tamper` says and then as
    % `add_compiled_code` says, when the fixture carries it ([RCTS.1.2.21],
    % [RCTS.1.2.31]), as `runner.py`'s fact-count driver edits it. Fails for a
    % string, which `tamper_placed` refuses here, for `drop_call_operand`,
    % which `tampered` does not make, and for an edit with no site.
    %
:- pred fact_count_edited(json_members::in, list(uint8)::in,
    list(uint8)::out) is semidet.

fact_count_edited(Expect, Bytes, Out) :-
    lookup_member(Expect, "tamper", TamperJ),
    not TamperJ = j_string(_),
    tampered(TamperJ, Bytes, Tampered),
    ( if lookup_member(Expect, "add_compiled_code", CodeJ) then
        compiled_code_added(CodeJ, Tampered, Out)
    else
        Out = Tampered
    ).

:- func judge_loaded(string, json_members, list(uint8))
    = {behave_result, maybe(list(string))}.

judge_loaded(Kind, Expect, Bytes) = Judged :-
    load_dsc(from_bytes(Bytes), Load),
    (
        Load = load_failed(Error),
        Judged = {behave_result(bo_load_failed, Kind,
            string.string(Error)), no}
    ;
        Load = loaded(P),
        Judged = run_expectation(Kind, Expect, P)
    ).

    % `runtime_error`'s `tamper`, as `runner.py`'s `_tampered` honours it. A
    % string XORs one byte of the compiled artefact with 0x01 before it is
    % loaded, at `dsc_sha256` (the stored hash's first byte) or `last_byte`,
    % and leaves the hash as it was [RDSC.3.6]. An object makes one structural
    % edit and re-seals: `truncate_tail` cuts N bytes off the end [RDSC.9.7],
    % `bad_wire_type` gives the first field tag of atom F's body wire type 7
    % [RDSC.9.5], `drop_schema_group` removes a schema's group [RDSC.8.7],
    % and `drop_terminal_parent` removes the BetaNode a rule's TerminalNode
    % names [RDSC.11.1]; `truncate_to` keeps the first N bytes, `drop_atom`
    % removes atom K's frame and `insert_bytes` puts octets before atom K,
    % for [RDSC.11.1]'s whole-frame rows. A refusal at load is matched
    % against `libds_load_status`; an edited artefact that loads is handed to
    % the inputs, whose fault `run_runtime_error` judges.
    % `drop_call_operand`'s artefact always loads, and `judge_run` hands it
    % to the steps itself. A list of two or more objects makes each edit in
    % order and seals once.
    %
    % A string's stored hash is found by its value, read off the untampered
    % artefact's decoded header. An object's re-seal, and an atom, are found
    % by this module's own walk of the frames (`reseal`, `atom_frames`), not
    % `dsc_seal.py`'s.
    %
:- func judge_tampered(string, json_members, json, list(uint8))
    = behave_result.

judge_tampered(Kind, Expect, TamperJ, Bytes) = Result :-
    ( if
        Kind = "runtime_error",
        tampered(TamperJ, Bytes, Tampered)
    then
        load_dsc(from_bytes(Tampered), Load),
        (
            % An edited artefact that loads goes to the inputs
            % ([RCTS.1.2.25]): a `set_field` index that names nothing faults
            % where the engine uses it ([RDSC.4a.9.1]). A run that raised
            % nothing fails.
            Load = loaded(P),
            Result = run_runtime_error(Expect, P)
        ;
            Load = load_failed(Error),
            WantCode = ( if lookup_member(Expect, "code", CJ),
                            CJ = j_string(C) then C else "" ),
            WantText = string.string(message_wants(Expect)),
            ( if libds_load_status(Error, Code, Text) then
                ( if
                    string.int_to_string(Code) = WantCode,
                    contains_all(Text, message_wants(Expect))
                then
                    Result = behave_result(bo_pass, Kind, "")
                else
                    Result = behave_result(bo_fail, Kind,
                        string.format("runtime_error: want code %s "
                            ++ "containing %s, got [%d] %s",
                            [s(WantCode), s(WantText), i(Code), s(Text)]))
                )
            else
                Result = behave_result(bo_fail, Kind,
                    "runtime_error: a load refusal with no libds status "
                        ++ "mapped: " ++ string.string(Error))
            )
        )
    else
        % [RCTS.1.2.21]: a tamper outside the set, with an argument of
        % another type, or with no site in the artefact fails the fixture.
        Result = behave_result(bo_fail, Kind,
            "tamper `" ++ string.string(TamperJ)
                ++ "` is no member of [RCTS.1.2.21]'s set, or has no site "
                ++ "in this artefact")
    ).

:- pred tampered(json::in, list(uint8)::in, list(uint8)::out) is semidet.

tampered(j_string(Site), Bytes, Out) :-
    tamper_offset(Site, Bytes, At),
    list.split_list(At, Bytes, Before, [B | After]),
    Out = Before ++ [B `xor` 1u8] ++ After.
tampered(j_object(O), Bytes, Out) :-
    structural_edit(j_object(O), Bytes, Edited),
    reseal(Edited, Out).
tampered(j_array(Edits), Bytes, Out) :-
    % [RCTS.1.2.21]'s list: two or more structural edits, each made to what
    % the ones before it left, then sealed once by `reseal`'s walk of the
    % edited bytes, since an edit can move or remove the header.
    structural_edits(Edits, Bytes, Edited),
    reseal(Edited, Out).

    % A list's edits, in order, each to what the ones before it left, not
    % re-sealed. FAILS on fewer than two, or on a member `structural_edit`
    % does not make: a string, a list, `drop_call_operand`, or an edit with
    % no site in what it is made to.
    %
:- pred structural_edits(list(json)::in, list(uint8)::in, list(uint8)::out)
    is semidet.

structural_edits(Edits, Bytes, Edited) :-
    Edits = [_, _ | _],
    list.foldl(structural_edit, Edits, Bytes, Edited).

    % One structural edit of [RCTS.1.2.21]'s set, an object of one member,
    % made to `Bytes` and not re-sealed. FAILS when the object names no
    % member, its argument is of another type, or it has no site.
    %
:- pred structural_edit(json::in, list(uint8)::in, list(uint8)::out)
    is semidet.

structural_edit(j_object(O), Bytes, Edited) :-
    members(O) = [Op - Arg],
    ( if Arg = j_int(N64) then
        N = int64.cast_to_int(N64),
        ( if Op = "truncate_tail" then
            N > 0,
            N < list.length(Bytes),
            Edited = list.take_upto(list.length(Bytes) - N, Bytes)
        else if Op = "truncate_to" then
            % The first N bytes kept; 0 leaves the artefact empty
            % ([RDSC.11.1]).
            N >= 0,
            N < list.length(Bytes),
            Edited = list.take_upto(N, Bytes)
        else if Op = "drop_atom" then
            atom_dropped(Bytes, N, Edited)
        else if
            ( Op = "duplicate_capability"
            ; Op = "swap_capabilities"
            )
        then
            capabilities_edited(Op, N, Bytes, Edited)
        else
            Op = "bad_wire_type",
            atom_body_offset(Bytes, N, At),
            list.split_list(At, Bytes, Before, [B | After]),
            Edited = Before ++ [(B /\ 0xF8u8) \/ 0x07u8] ++ After
        )
    else if Arg = j_object(AO) then
        ( if Op = "set_field" then
            % One field of one RETE node, found by its `node_id`, or of
            % occurrence I of the atoms numbered F.
            members(AO) = [Selector - SelectorJ, "path" - j_array(PathJ),
                "value" - ValueJ],
            field_selector(Selector, SelectorJ, Where),
            field_path(PathJ, Path),
            field_write_of(ValueJ, Value),
            field_set(Bytes, Where, Path, Value, Edited)
        else if Op = "insert_bytes" then
            % Octets before atom K, or after the last.
            members(AO) = ["at" - j_int(K64), "hex" - j_string(Hex)],
            K64 >= 0i64,
            lower_hex_octets(Hex, Octets),
            Octets = [_ | _],
            bytes_inserted(Bytes, int64.cast_to_int(K64), Octets, Edited)
        else if Op = "nest_action_expr" then
            members(AO) = ["levels" - j_int(L64), "rule" - j_string(Rule)],
            Levels = int64.cast_to_int(L64),
            Levels >= 1,
            action_edited(Bytes, Rule, [0], expr_nested(Levels), Edited)
        else
            % [RDSC.4a.9.3]: one call's `op` set to N, at an action's
            % `expr` or inside an assignment's expression.
            members(AO) = ["op" - j_int(N64), "rule" - j_string(Rule)],
            N64 >= 0i64,
            N = int64.cast_to_int(N64),
            ( if Op = "set_action_op" then
                action_edited(Bytes, Rule, [0], action_op_set(N), Edited)
            else
                Op = "set_assign_op",
                action_edited(Bytes, Rule, [1, 2], assign_op_set(N), Edited)
            )
        )
    else
        Arg = j_string(Name),
        ( if Op = "drop_schema_group" then
            drop_schema_group(Bytes, Name, Edited)
        else if Op = "drop_terminal_parent" then
            drop_terminal_parent(Bytes, Name, Edited)
        else if Op = "drop_action_expr" then
            action_edited(Bytes, Name, [0], without_first(2), Edited)
        else if Op = "clear_action_expr" then
            action_edited(Bytes, Name, [0], expr_cleared, Edited)
        else
            Op = "drop_assign_expr",
            action_edited(Bytes, Name, [1, 2], assign_expr_dropped, Edited)
        )
    ).

    % [RDSC.11.3]'s four load refusals, as `dsc_seal.py` makes them:
    % the first action (field 6) of the one TerminalNode (270, `rule_name`
    % field 3) realizing `Rule` whose kind (field 1, 0 when absent) is in
    % `Kinds`, edited by `Edit`, then the action and the atom re-framed.
    % FAILS when no or several terminals realize `Rule`, no action has such a
    % kind, the edit fails, or a body does not walk. Not re-sealed. The walk
    % is this module's, not `dsc_seal.py`'s.
    %
    %   * `drop_action_expr`: an ACTION_CALL (0) loses `expr` (field 2);
    %   * `clear_action_expr`: its `expr` holds an Expr of no field, so no
    %     member of `kind` is set;
    %   * `drop_assign_expr`: an ACTION_ASSERT or ACTION_LOGICAL_ASSERT (1, 2)
    %     has its first SlotAssign (field 4) lose `expr` (field 2);
    %   * `nest_action_expr`: an ACTION_CALL's `expr` is wrapped `Levels` times
    %     as the operand (UnopExpr field 2) of a `not` (Expr field 7, op
    %     UNOP_NOT written absent), so every Expr in it is `Levels` deeper.
    %
:- pred action_edited(list(uint8)::in, string::in, list(int)::in,
    pred(list(uint8), list(uint8))::in(pred(in, out) is semidet),
    list(uint8)::out) is semidet.

action_edited(Bytes, Rule, Kinds, Edit, Out) :-
    RuleBytes = utf8_bytes(Rule),
    Terms = list.filter(
        ( pred({N, _, _, BS, BE}::in) is semidet :-
            N = 270,
            field_bytes(Bytes, BS, BE, 3, RuleBytes)
        ), atom_frames(Bytes, 0)),
    Terms = [{_, FStart, FEnd, BStart, BEnd}],
    list.split_list(BStart, Bytes, _, FromBody),
    list.split_list(BEnd - BStart, FromBody, Term, _),
    body_fields(Term, 0, list.length(Term), TFields),
    list.find_first_match(
        ( pred({AN, _, _, A}::in) is semidet :-
            AN = 6,
            list.member(field_varint_or_zero(A, 0, list.length(A), 1), Kinds)
        ), tamper_spans(TFields, list.length(Term)), {_, S, E, Action}),
    Edit(Action, NewAction),
    tamper_replace_span(Term, S, E, tamper_delimited(6, NewAction), NewTerm),
    Inner = tamper_delimited(270, NewTerm),
    tamper_replace_span(Bytes, FStart, FEnd,
        [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner, Out).

    % [RBND.1.3]'s malformed `capabilities` list, as `dsc_seal.py`'s
    % `capabilities_edited` makes it: in the DscHeader (263, the first atom),
    % the packed `capabilities` (field 13), every entry one varint byte, has
    % entry `I` + 1 set to entry `I`'s value (`duplicate_capability`) or the
    % two swapped (`swap_capabilities`), in place, so no length moves. FAILS
    % when the first atom is no DscHeader, it carries no packed list, an entry
    % is wider than a byte, or there is no entry `I` + 1. Not re-sealed. The
    % walk is this module's own, not `dsc_seal.py`'s.
    %
:- pred capabilities_edited(string::in, int::in, list(uint8)::in,
    list(uint8)::out) is semidet.

capabilities_edited(Op, I, Bytes, Out) :-
    atom_frames(Bytes, 0) = [{263, _, _, BStart, BEnd} | _],
    body_fields(Bytes, BStart, BEnd, Fields),
    list.find_first_match(
        ( pred({FieldNum, _, _, _}::in) is semidet :- FieldNum = 13 ),
        tamper_spans(Fields, BEnd), {_, _, FieldEnd, Caps}),
    list.all_true(( pred(Cap::in) is semidet :- Cap /\ 0x80u8 = 0u8 ), Caps),
    I >= 0,
    list.index0(Caps, I, A),
    list.index0(Caps, I + 1, B),
    ( if Op = "duplicate_capability" then
        NewA = A,
        NewB = A
    else
        Op = "swap_capabilities",
        NewA = B,
        NewB = A
    ),
    At = FieldEnd - list.length(Caps) + I,
    list.split_list(At, Bytes, Before, [_, _ | After]),
    Out = Before ++ [NewA, NewB] ++ After.

    % `Body` without its first field `Field`. FAILS when it has none or does
    % not walk.
    %
:- pred without_first(int::in, list(uint8)::in, list(uint8)::out) is semidet.

without_first(Field, Body, Out) :-
    body_fields(Body, 0, list.length(Body), Fields),
    list.find_first_match(
        ( pred({N, _, _, _}::in) is semidet :- N = Field ),
        tamper_spans(Fields, list.length(Body)), {_, S, E, _}),
    tamper_replace_span(Body, S, E, [], Out).

:- pred expr_cleared(list(uint8)::in, list(uint8)::out) is semidet.

expr_cleared(Action, Out) :-
    tamper_with_first(Action, 2, [], Out).

:- pred assign_expr_dropped(list(uint8)::in, list(uint8)::out) is semidet.

assign_expr_dropped(Action, Out) :-
    body_fields(Action, 0, list.length(Action), Fields),
    list.find_first_match(
        ( pred({N, _, _, _}::in) is semidet :- N = 4 ),
        tamper_spans(Fields, list.length(Action)), {_, S, E, Assign}),
    without_first(2, Assign, NewAssign),
    tamper_replace_span(Action, S, E, tamper_delimited(4, NewAssign), Out).

    % `set_action_op` and `set_assign_op` ([RCTS.1.2.21]), as
    % `dsc_seal.py` makes them: the call (Expr field 8) that is an action's
    % `expr` (field 2), or the `expr` (field 2) of an assert's first SlotAssign
    % (field 4), has its `op` (CallExpr field 3) dropped and `N` written after
    % its other fields. FAILS when that `expr` is no call or the call has no
    % `op` written.
    %
:- pred action_op_set(int::in, list(uint8)::in, list(uint8)::out) is semidet.

action_op_set(N, Action, Out) :-
    field_bytes(Action, 0, list.length(Action), 2, Expr),
    call_op_set(N, Expr, NewExpr),
    tamper_with_first(Action, 2, NewExpr, Out).

:- pred assign_op_set(int::in, list(uint8)::in, list(uint8)::out) is semidet.

assign_op_set(N, Action, Out) :-
    body_fields(Action, 0, list.length(Action), Fields),
    list.find_first_match(
        ( pred({F, _, _, _}::in) is semidet :- F = 4 ),
        tamper_spans(Fields, list.length(Action)), {_, S, E, Assign}),
    field_bytes(Assign, 0, list.length(Assign), 2, Expr),
    call_op_set(N, Expr, NewExpr),
    tamper_with_first(Assign, 2, NewExpr, NewAssign),
    tamper_replace_span(Action, S, E, tamper_delimited(4, NewAssign), Out).

:- pred call_op_set(int::in, list(uint8)::in, list(uint8)::out) is semidet.

call_op_set(N, Expr, Out) :-
    field_bytes(Expr, 0, list.length(Expr), 8, Call),
    without_first(3, Call, Rest),
    tamper_with_first(Expr, 8, Rest ++ t_int(3, N), Out).

:- pred expr_nested(int::in, list(uint8)::in, list(uint8)::out) is semidet.

expr_nested(Levels, Action, Out) :-
    field_bytes(Action, 0, list.length(Action), 2, Expr),
    tamper_with_first(Action, 2, wrap_not(Levels, Expr), Out).

    % `action_edited`'s four edits and `tampered`'s argument shapes, run on
    % every build: the cases `test_runner_codes.py`'s `TestExpressionShapes`
    % runs on `dsc_seal.py`.
    % @spec [RCTS.1.2.21]
    %
:- pred expr_shape_checks(tally::in, tally::out, io::di, io::uo) is det.

expr_shape_checks(!T, !IO) :-
    Lit = t_int(1, 1),
    CallExpr = tamper_delimited(8, tamper_delimited(2, Lit) ++ t_int(3, 47)),
    Call = tamper_delimited(2, CallExpr),
    Assert = t_int(1, 1) ++ tamper_delimited(3, utf8_bytes("Out")),
    Assign = t_int(1, 0) ++ tamper_delimited(2, Lit),
    Assigning = Assert ++ tamper_delimited(4, Assign)
        ++ tamper_delimited(4, Assign),
    % Fails on: the assert or the second call edited, the `expr` left in
    % place, or a stale frame.
    check("RCTS.1.2.21:drop_action_expr empties the first call only",
        ( if
            action_edited(t_term("r", [Assert, Call, Call]), "r", [0],
                without_first(2), Dropped),
            Dropped = t_term("r", [Assert, [], Call])
          then yes else no ), !T, !IO),
    % Fails on: the `expr` removed rather than emptied, which is the third
    % shape and not this one.
    check("RCTS.1.2.21:clear_action_expr leaves an Expr of no kind",
        ( if
            action_edited(t_term("r", [Call]), "r", [0], expr_cleared,
                Cleared),
            Cleared = t_term("r", [tamper_delimited(2, [])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:drop_assign_expr empties the first assignment only",
        ( if
            action_edited(t_term("r", [Call, Assigning]), "r", [1, 2],
                assign_expr_dropped, NoAssign),
            NoAssign = t_term("r", [Call, Assert
                ++ tamper_delimited(4, t_int(1, 0))
                ++ tamper_delimited(4, Assign)])
          then yes else no ), !T, !IO),
    % Fails on: a level too few or too many, which moves the boundary a
    % vector sits on, or the wrap put inside the call.
    check("RCTS.1.2.21:nest_action_expr wraps the whole expr levels times",
        ( if
            action_edited(t_term("r", [Call]), "r", [0], expr_nested(2),
                Nested),
            Nested = t_term("r", [tamper_delimited(2,
                tamper_delimited(7, tamper_delimited(2,
                    tamper_delimited(7, tamper_delimited(2, CallExpr)))))])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:the four shapes without a site",
        ( if
            not action_edited(t_term("r", [Assigning]), "r", [0],
                without_first(2), _),
            not action_edited(t_term("r", [Assert, Call]), "r", [1, 2],
                assign_expr_dropped, _),
            not action_edited(t_term("r", [[]]), "r", [0], without_first(2),
                _),
            not action_edited(t_term("r", [[]]), "r", [0], expr_cleared, _),
            not action_edited(t_term("r", [Call]) ++ t_term("r", [Call]),
                "r", [0], without_first(2), _),
            not action_edited(t_term("r", [Call]), "q", [0],
                without_first(2), _)
          then yes else no ), !T, !IO),
    Art = t_term("r", [Call]),
    Nest = (func(NestMs) = j_object(object(["nest_action_expr"
        - j_object(object(NestMs))]))),
    % Judged by `structural_edit`, before the seal: `Art` has no header, so
    % `tampered` refuses every object for the seal and could not fail here.
    % The first arm shows the well-formed argument is taken.
    check("RCTS.1.2.21:an argument of another shape is refused",
        ( if
            structural_edit(j_object(object(["drop_action_expr"
                - j_string("r")])), Art, _),
            structural_edit(Nest(["levels" - j_int(1i64),
                "rule" - j_string("r")]), Art, _),
            not structural_edit(j_object(object(["drop_action_expr"
                - j_int(1i64)])), Art, _),
            not structural_edit(j_object(object(["nest_action_expr"
                - j_string("r")])), Art, _),
            not structural_edit(Nest(["rule" - j_string("r")]), Art, _),
            not structural_edit(Nest(["levels" - j_int(0i64),
                "rule" - j_string("r")]), Art, _),
            not structural_edit(Nest(["levels" - j_bool(yes),
                "rule" - j_string("r")]), Art, _),
            not structural_edit(Nest(["levels" - j_int(1i64),
                "rule" - j_string("r"), "x" - j_int(1i64)]), Art, _)
          then yes else no ), !T, !IO),
    set_op_checks(!T, !IO).

    % `set_action_op` and `set_assign_op`, run on every build: the
    % cases `test_runner_codes.py`'s `TestSetOp` runs on `dsc_seal.py`.
    % @spec [RCTS.1.2.21]
    %
:- pred set_op_checks(tally::in, tally::out, io::di, io::uo) is det.

set_op_checks(!T, !IO) :-
    Lit = t_int(1, 1),
    CallOf = (func(COp) = tamper_delimited(8, tamper_delimited(2, Lit)
        ++ t_int(3, COp))),
    CallAction = (func(AOp) = tamper_delimited(2, CallOf(AOp))),
    Assert = t_int(1, 1) ++ tamper_delimited(3, utf8_bytes("Out")),
    LitAssign = tamper_delimited(4, t_int(1, 0) ++ tamper_delimited(2, Lit)),
    Assigning = (func(SOp) = Assert ++ tamper_delimited(4, t_int(1, 0)
        ++ tamper_delimited(2, CallOf(SOp))) ++ LitAssign),
    % Fails on: the assert or the second call edited, the operand moved, or
    % a stale frame (109 is one byte, 1000 two).
    check("RCTS.1.2.21:set_action_op rewrites the first call action only",
        ( if
            action_edited(t_term("r", [Assigning(1), CallAction(47),
                CallAction(47)]), "r", [0], action_op_set(109), Set109),
            Set109 = t_term("r", [Assigning(1), CallAction(109),
                CallAction(47)]),
            action_edited(t_term("r", [CallAction(47)]), "r", [0],
                action_op_set(1000), Set1000),
            Set1000 = t_term("r", [CallAction(1000)])
          then yes else no ), !T, !IO),
    % Fails on: the call action edited instead, or the second assignment.
    check("RCTS.1.2.21:set_assign_op rewrites the first assignment's call only",
        ( if
            action_edited(t_term("r", [CallAction(47), Assigning(1)]), "r",
                [1, 2], assign_op_set(109), SetAssign),
            SetAssign = t_term("r", [CallAction(47), Assigning(109)])
          then yes else no ), !T, !IO),
    NoOp = tamper_delimited(2, tamper_delimited(8, tamper_delimited(2, Lit))),
    Plain = Assert ++ LitAssign,
    Op = (func(OpName, ORule, ON) = j_object(object([OpName
        - j_object(object(["op" - ON, "rule" - j_string(ORule)]))]))),
    Art = t_term("r", [CallAction(47), Assigning(1)]),
    % Fails on: a pass that edits nothing and reports success, or an argument
    % of another shape taken.
    check("RCTS.1.2.21:set_action_op and set_assign_op without a site",
        ( if
            not action_edited(t_term("r", [tamper_delimited(2, Lit)]), "r",
                [0], action_op_set(109), _),
            not action_edited(t_term("r", [NoOp]), "r", [0],
                action_op_set(109), _),
            not action_edited(t_term("r", [Plain]), "r", [0],
                action_op_set(109), _),
            not action_edited(t_term("r", [Plain]), "r", [1, 2],
                assign_op_set(109), _),
            not action_edited(t_term("r", [Assert, CallAction(47)]), "r",
                [1, 2], assign_op_set(109), _),
            % Judged by `structural_edit`, before the seal: `Art` has no
            % header, so `tampered` refuses every object for the seal. The
            % first two show the well-formed arguments are taken.
            structural_edit(Op("set_action_op", "r", j_int(109i64)), Art, _),
            structural_edit(Op("set_assign_op", "r", j_int(109i64)), Art, _),
            not structural_edit(Op("set_action_op", "q", j_int(109i64)), Art,
                _),
            not structural_edit(Op("set_action_op", "r", j_int(-1i64)), Art,
                _),
            not structural_edit(Op("set_assign_op", "r", j_bool(yes)), Art, _),
            not structural_edit(Op("set_assign_op", "r", j_string("109")), Art,
                _),
            not structural_edit(j_object(object(["set_action_op"
                - j_object(object(["rule" - j_string("r")]))])), Art, _),
            not structural_edit(j_object(object(["set_action_op"
                - j_object(object(["op" - j_int(109i64),
                    "rule" - j_string("r"), "x" - j_int(1i64)]))])), Art, _),
            not structural_edit(j_object(object(["set_assign_op"
                - j_string("r")])), Art, _)
          then yes else no ), !T, !IO),
    set_field_checks(!T, !IO),
    compiled_code_checks(!T, !IO).

    % `add_compiled_code`, run on every build: the cases
    % `test_runner_codes.py`'s `TestAddCompiledCode` runs on `dsc_seal.py`,
    % over a TerminalNode with node 3 (`t_term`). The atoms are written out
    % by hand here, not by `compiled_code_atom`.
    % @spec [RCTS.1.2.31]
    %
:- pred compiled_code_checks(tally::in, tally::out, io::di, io::uo) is det.

compiled_code_checks(!T, !IO) :-
    Term = t_term("r", []),
    Node = (func(N) = j_object(object(["node" - j_int(N)]))),
    Atom = (func(Arch) = [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner :-
        Body = [0x0Au8] ++ varint_u8(string.length(Arch))
            ++ utf8_bytes(Arch) ++ [0x10u8, 3u8, 0x18u8, 3u8, 0x22u8, 0x40u8]
            ++ list.duplicate(64, 0u8),
        Inner = tamper_delimited(298, Body)),
    % Fails on: an atom anywhere but the end, an arch left out or out of
    % order, a field out of ascending order, or the wrong node or kind.
    check("RCTS.1.2.31:add_compiled_code appends one RHS per well-known arch "
            ++ "after the last atom",
        ( if
            compiled_code_appended(Node(3i64), Term, Out),
            Out = Term ++ Atom("amd64") ++ Atom("arm64") ++ Atom("rv64g")
                ++ Atom("rv64gc")
          then yes else no ), !T, !IO),
    % Fails on: a pass that edits nothing and reports success, or an
    % argument of another shape taken.
    check("RCTS.1.2.31:add_compiled_code without a site, or off its shape",
        ( if
            not compiled_code_appended(Node(4i64), Term, _),
            not compiled_code_appended(Node(3i64), Term ++ Term, _),
            not compiled_code_appended(Node(3i64), Term ++ [0x0Au8], _),
            not compiled_code_appended(Node(0i64), Term, _),
            not compiled_code_appended(j_object(object(["node" - j_int(3i64),
                "arch" - j_string("amd64")])), Term, _),
            not compiled_code_appended(j_object(object(
                ["node" - j_string("3")])), Term, _),
            not compiled_code_appended(j_int(3i64), Term, _)
          then yes else no ), !T, !IO).

    % `set_field`, run on every build: the cases
    % `test_runner_codes.py`'s `TestSetField` runs on `dsc_seal.py`, over the
    % same AlphaNode: node 5, schema "S", an EQ test on slot 0 against 1 and
    % a CMP (kind 1) on slot 1, op GT (3), against 2.
    % @spec [RCTS.1.2.21]
    %
:- pred set_field_checks(tally::in, tally::out, io::di, io::uo) is det.

set_field_checks(!T, !IO) :-
    Eq = t_int(2, 0) ++ tamper_delimited(4, t_int(1, 1)),
    Cmp = t_int(1, 1) ++ t_int(2, 1) ++ t_int(3, 3)
        ++ tamper_delimited(4, t_int(1, 2)),
    Alpha = (func(Body) = [0x0Au8]
        ++ varint_u8(list.length(tamper_delimited(268, Body)))
        ++ tamper_delimited(268, Body)),
    Name = tamper_delimited(2, utf8_bytes("S")),
    Tests = tamper_delimited(3, Eq) ++ tamper_delimited(3, Cmp),
    Art = Alpha(t_int(1, 5) ++ Name ++ Tests),
    Set = (func(Node, Path, Value) = j_object(object(["set_field"
        - j_object(object(["node" - j_int(int64.from_int(Node)),
            "path" - j_array(list.map(
                (func(P) = j_int(int64.from_int(P))), Path)),
            "value" - Value]))]))),
    % Fails on: the id left beside the new one, the edit put elsewhere, or a
    % stale frame (70000 is three varint bytes).
    check("RCTS.1.2.21:set_field writes its field after the others, in the "
            ++ "occurrence its path selects",
        ( if
            structural_edit(Set(5, [1], j_int(0i64)), Art, Zero),
            Zero = Alpha(Name ++ Tests ++ t_int(1, 0)),
            structural_edit(Set(5, [2], j_string("")), Art, NoSchema),
            NoSchema = Alpha(t_int(1, 5) ++ Tests ++ tamper_delimited(2, [])),
            structural_edit(Set(5, [3, 1, 2], j_int(70000i64)), Art, Slot),
            Slot = Alpha(t_int(1, 5) ++ Name ++ tamper_delimited(3, Eq)
                ++ tamper_delimited(3, t_int(1, 1) ++ t_int(3, 3)
                    ++ tamper_delimited(4, t_int(1, 2)) ++ t_int(2, 70000)))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:set_field null removes a field, \"\" empties a message",
        ( if
            structural_edit(Set(5, [3, 0, 4], j_null), Art, Dropped),
            Dropped = Alpha(t_int(1, 5) ++ Name
                ++ tamper_delimited(3, t_int(2, 0)) ++ tamper_delimited(3, Cmp)),
            structural_edit(Set(5, [3, 0, 4], j_string("")), Art, Emptied),
            Emptied = Alpha(t_int(1, 5) ++ Name
                ++ tamper_delimited(3, t_int(2, 0) ++ tamper_delimited(4, []))
                ++ tamper_delimited(3, Cmp))
          then yes else no ), !T, !IO),
    % Fails on: a pass that edits nothing and reports success, or an
    % argument of another shape taken.
    check("RCTS.1.2.21:set_field without a site, or off its shape",
        ( if
            not structural_edit(Set(99, [1], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [3, 2, 2], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [1, 0, 1], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [5], j_null), Art, _),
            not structural_edit(Set(5, [1], j_int(0i64)), Art ++ Art, _),
            not structural_edit(Set(0, [1], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [3, 0], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [0], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [3, -1, 2], j_int(0i64)), Art, _),
            not structural_edit(Set(5, [1], j_int(-1i64)), Art, _),
            not structural_edit(Set(5, [1], j_bool(yes)), Art, _),
            not structural_edit(j_object(object(["set_field"
                - j_object(object(["node" - j_int(5i64),
                    "path" - j_array([j_int(1i64)])]))])), Art, _)
          then yes else no ), !T, !IO),
    % `atom` and `f64`, over two Slot atoms (257) of schema "S",
    % slots "m" and "n", the cases `TestSetField` runs on `dsc_seal.py`.
    SlotM = [0x0Au8, 0x01u8, 0x53u8, 0x12u8, 0x01u8, 0x6Du8, 0x18u8, 0x01u8],
    SlotN = [0x0Au8, 0x01u8, 0x53u8, 0x12u8, 0x01u8, 0x6Eu8, 0x18u8, 0x01u8],
    SlotAtom = (func(SBody) = [0x0Au8] ++ varint_u8(list.length(SInner))
            ++ SInner :-
        SInner = tamper_delimited(257, SBody)),
    Slots = SlotAtom(SlotM) ++ SlotAtom(SlotN),
    AtomSet = (func(AF, AI, APath, AValue) = j_object(object(["set_field"
        - j_object(object(["atom" - j_array([j_int(AF), j_int(AI)]),
            "path" - j_array(list.map(
                (func(AP) = j_int(int64.from_int(AP))), APath)),
            "value" - AValue]))]))),
    % Fails on: the first occurrence edited for the second, or `atom` read
    % as a node id.
    check("RCTS.1.2.21:set_field finds an atom by its number and occurrence",
        ( if
            structural_edit(AtomSet(257i64, 1i64, [2], j_string("k")), Slots,
                Named),
            Named = SlotAtom(SlotM) ++ SlotAtom([0x0Au8, 0x01u8, 0x53u8,
                0x18u8, 0x01u8] ++ tamper_delimited(2, utf8_bytes("k"))),
            not structural_edit(AtomSet(257i64, 2i64, [2], j_string("k")),
                Slots, _),
            not structural_edit(AtomSet(258i64, 0i64, [2], j_string("k")),
                Slots, _),
            not structural_edit(AtomSet(0i64, 0i64, [2], j_string("k")),
                Slots, _),
            not structural_edit(AtomSet(257i64, -1i64, [2], j_string("k")),
                Slots, _)
          then yes else no ), !T, !IO),
    Double = (func(DH) = j_object(object(["f64" - j_string(DH)]))),
    % Fails on: the bits written most significant octet first, as a
    % varint, or with another wire type, so a loader would read some value
    % other than the NaN a fixture means [RDSC.9.10].
    check("RCTS.1.2.21:set_field writes an f64 as a double is written",
        ( if
            structural_edit(AtomSet(257i64, 0i64, [7],
                Double("7ff0000000000001")), SlotAtom(SlotN), Nan),
            Nan = SlotAtom(SlotN ++ [0x39u8, 0x01u8, 0u8, 0u8, 0u8, 0u8,
                0u8, 0xF0u8, 0x7Fu8]),
            not structural_edit(AtomSet(257i64, 0i64, [7],
                Double("7FF0000000000001")), SlotAtom(SlotN), _),
            not structural_edit(AtomSet(257i64, 0i64, [7],
                Double("7ff00000000001")), SlotAtom(SlotN), _),
            not structural_edit(AtomSet(257i64, 0i64, [7],
                j_object(object(["g64" - j_string("7ff0000000000001")]))),
                SlotAtom(SlotN), _)
          then yes else no ), !T, !IO).

:- func t_int(int, int) = list(uint8).

t_int(Field, Value) = varint_u8(Field * 8) ++ varint_u8(Value).

    % A TerminalNode atom (270) realizing `Rule`, with node 3, parent 1, and
    % `Actions` as its actions (field 6).
    %
:- func t_term(string, list(list(uint8))) = list(uint8).

t_term(Rule, Actions) = [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner :-
    Body = t_int(1, 3) ++ t_int(2, 1) ++ tamper_delimited(3, utf8_bytes(Rule))
        ++ list.condense(list.map(tamper_delimited(6), Actions)),
    Inner = tamper_delimited(270, Body).

    % `Expr` wrapped `N` times as the operand of a `not`.
    %
:- func wrap_not(int, list(uint8)) = list(uint8).

wrap_not(N, Expr) =
    ( if N =< 0 then
        Expr
    else
        wrap_not(N - 1, tamper_delimited(7, tamper_delimited(2, Expr)))
    ).

    % `drop_schema_group`: `Bytes` without schema `Name`'s group, its
    % lifecycle atom (SchemaLogical 299 or SchemaTtl 300) through its
    % SchemaDef (256) [RDSC.8.1], so an AlphaNode naming it names a schema
    % the artefact does not declare [RDSC.8.7]. `dsc_seal.py`'s
    % `drop_schema_group`, by this module's own walk of the frames.
    %
:- pred drop_schema_group(list(uint8)::in, string::in, list(uint8)::out)
    is semidet.

drop_schema_group(Bytes, Name, Out) :-
    group_span(Bytes, utf8_bytes(Name), atom_frames(Bytes, 0), no, Start,
        End),
    cut_out(Bytes, Start, End, Out).

:- pred group_span(list(uint8)::in, list(uint8)::in,
    list({int, int, int, int, int})::in, maybe(int)::in, int::out, int::out)
    is semidet.

group_span(Bytes, Name, [{Num, FStart, FEnd, BStart, BEnd} | Rest], Life,
        Start, End) :-
    ( if Num = 256, field_bytes(Bytes, BStart, BEnd, 1, Name) then
        Life = yes(Start),
        End = FEnd
    else
        Life1 = ( if ( Num = 299 ; Num = 300 ) then yes(FStart) else Life ),
        group_span(Bytes, Name, Rest, Life1, Start, End)
    ).

    % `drop_terminal_parent`: `Bytes` without the BetaNode (269) that rule
    % `Rule`'s TerminalNode (270, `rule_name` field 3) names as its
    % `parent_beta_id` (field 2), so that id names no node [RDSC.11.1].
    % `dsc_seal.py`'s `drop_terminal_parent`.
    %
:- pred drop_terminal_parent(list(uint8)::in, string::in, list(uint8)::out)
    is semidet.

drop_terminal_parent(Bytes, Rule, Out) :-
    Frames = atom_frames(Bytes, 0),
    RuleBytes = utf8_bytes(Rule),
    list.find_first_match(
        ( pred({N, _, _, BS, BE}::in) is semidet :-
            N = 270,
            field_bytes(Bytes, BS, BE, 3, RuleBytes)
        ), Frames, {_, _, _, TStart, TEnd}),
    Parent = field_varint_or_zero(Bytes, TStart, TEnd, 2),
    Parent \= 0,
    list.find_first_match(
        ( pred({N, _, _, BS, BE}::in) is semidet :-
            N = 269,
            field_varint_or_zero(Bytes, BS, BE, 1) = Parent
        ), Frames, {_, FStart, FEnd, _, _}),
    cut_out(Bytes, FStart, FEnd, Out).

    % [RCTS.1.2.21]'s `set_field`: in the one AlphaNode, BetaNode or
    % TerminalNode (268, 269, 270) whose `node_id` (field 1) is `Node`, the
    % field `Path` names is set to `Value` (`set_in`), the atom re-framed.
    % It reaches the body refusals no compiler writes: [RDSC.4a.3]'s zero id,
    % [RDSC.4a.6]'s AlphaNode naming no schema, [RDSC.4a.6.1]'s malformed
    % AlphaTest, [RDSC.4a.9.1]'s index past its table. FAILS when no or
    % several nodes carry the id, or the path has no site. Not re-sealed.
    % `dsc_seal.py`'s `set_field`, by this module's own walk.
    %
    % Not `field_value`, which is `ds.wire`'s.
:- type field_write
    --->    fv_varint(int)
    ;       fv_fixed64(list(uint8))
            % A `double`'s eight octets, least significant first.
    ;       fv_bytes(list(uint8))
    ;       fv_remove.

    % Where `set_field` edits: the RETE node whose `node_id` is N, or
    % occurrence I, from 0, of the atoms numbered F.
    %
:- type field_site
    --->    by_node(int)
    ;       by_atom(int, int).

:- pred field_selector(string::in, json::in, field_site::out) is semidet.

field_selector("node", j_int(Node64), by_node(int64.cast_to_int(Node64))) :-
    Node64 >= 1i64.
field_selector("atom", j_array([j_int(F64), j_int(I64)]),
        by_atom(int64.cast_to_int(F64), int64.cast_to_int(I64))) :-
    F64 >= 1i64,
    I64 >= 0i64.

:- pred field_set(list(uint8)::in, field_site::in, list(int)::in,
    field_write::in, list(uint8)::out) is semidet.

field_set(Bytes, Where, Path, Value, Edited) :-
    Frames = atom_frames(Bytes, 0),
    (
        Where = by_node(Node),
        Nodes = list.filter(
            ( pred({N, _, _, BS, BE}::in) is semidet :-
                ( N = 268 ; N = 269 ; N = 270 ),
                field_varint_or_zero(Bytes, BS, BE, 1) = Node
            ), Frames),
        Nodes = [Hit]
    ;
        Where = by_atom(Number, Occurrence),
        Numbered = list.filter(
            ( pred({N, _, _, _, _}::in) is semidet :- N = Number ), Frames),
        list.index0(Numbered, Occurrence, Hit)
    ),
    Hit = {Num, FStart, FEnd, BStart, BEnd},
    list.split_list(BStart, Bytes, _, FromBody),
    list.split_list(BEnd - BStart, FromBody, Body, _),
    set_in(Body, Path, Value, NewBody),
    Inner = tamper_delimited(Num, NewBody),
    tamper_replace_span(Bytes, FStart, FEnd,
        [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner, Edited).

    % `Body` with the field `Path` names set to `Value`: the message each
    % (field, occurrence) pair of the path selects, then the last field of
    % it, every occurrence of which is removed and, but for `fv_remove`,
    % written once after the message's other fields. Every message on the
    % way is re-framed. FAILS when the path has no site: an occurrence the
    % message does not carry, a selected field that is not length-delimited,
    % or a field to remove that the message does not carry.
    % `dsc_seal.py`'s `_set_in`.
    %
:- pred set_in(list(uint8)::in, list(int)::in, field_write::in,
    list(uint8)::out) is semidet.

set_in(Body, Path, Value, Out) :-
    body_fields(Body, 0, list.length(Body), Fields),
    Spans = tamper_spans(Fields, list.length(Body)),
    ( if Path = [Field] then
        Kept = list.condense(list.filter_map(
            ( func({N0, S0, E0, _}) = Span is semidet :-
                N0 \= Field,
                list.split_list(S0, Body, _, FromS),
                list.split_list(E0 - S0, FromS, Span, _)
            ), Spans)),
        (
            Value = fv_remove,
            list.length(Kept) < list.length(Body),
            Out = Kept
        ;
            Value = fv_varint(V),
            Out = Kept ++ t_int(Field, V)
        ;
            Value = fv_fixed64(Octets),
            Out = Kept ++ varint_u8(Field * 8 + 1) ++ Octets
        ;
            Value = fv_bytes(B),
            Out = Kept ++ tamper_delimited(Field, B)
        )
    else
        Path = [Outer, Index | Rest],
        Hits = list.filter(
            ( pred({N1, S1, _, _}::in) is semidet :-
                N1 = Outer,
                byte_varint(Body, S1, 0, 0, Key, _),
                Key /\ 7 = 2
            ), Spans),
        list.index0(Hits, Index, {_, S, E, Inner}),
        set_in(Inner, Rest, Value, NewInner),
        tamper_replace_span(Body, S, E, tamper_delimited(Outer, NewInner), Out)
    ).

    % A `set_field` path: a field number of at least 1, then any number of
    % (occurrence index of at least 0, field number) pairs. `runner.py`'s
    % `_is_field_path`.
    %
:- pred field_path(list(json)::in, list(int)::out) is semidet.

field_path(Js, Path) :-
    list.map(
        ( pred(J::in, I::out) is semidet :-
            J = j_int(I64),
            I = int64.cast_to_int(I64)
        ), Js, Path),
    field_path_ok(Path).

:- pred field_path_ok(list(int)::in) is semidet.

field_path_ok([F | Rest]) :-
    F >= 1,
    (
        Rest = []
    ;
        Rest = [I | More],
        I >= 0,
        field_path_ok(More)
    ).

    % A `set_field` value: null removes, an integer of at least 0 is a
    % varint, a string is length-delimited bytes, and `{"f64": H}`, H 16
    % lowercase hexadecimal digits spelling a `double`'s bits most
    % significant first, is those eight octets least significant first.
    %
:- pred field_write_of(json::in, field_write::out) is semidet.

field_write_of(j_null, fv_remove).
field_write_of(j_int(V64), fv_varint(V)) :-
    V64 >= 0i64,
    V = int64.cast_to_int(V64).
field_write_of(j_string(S), fv_bytes(B)) :-
    B = utf8_bytes(S).
field_write_of(j_object(O), fv_fixed64(list.reverse(BigEndian))) :-
    members(O) = ["f64" - j_string(Hex)],
    lower_hex_octets(Hex, BigEndian),
    list.length(BigEndian) = 8.

    % The octets `Hex` spells, two digits to an octet, most significant digit
    % first. FAILS on an odd count, a character that is not a hexadecimal
    % digit, or an uppercase one, as [RCTS.1.2.21] admits only lowercase.
    %
:- pred lower_hex_octets(string::in, list(uint8)::out) is semidet.

lower_hex_octets(Hex, Octets) :-
    string.to_lower(Hex) = Hex,
    hex_bytes(Hex, Octets).

    % `drop_atom`: `Bytes` without the frame of atom `K`, counted
    % from 0 by `atom_frames`, so 0 removes the DscHeader. FAILS when the walk
    % reaches no atom `K`. Not re-sealed. `dsc_seal.py`'s `drop_atom`, by
    % this module's own walk.
    %
:- pred atom_dropped(list(uint8)::in, int::in, list(uint8)::out) is semidet.

atom_dropped(Bytes, K, Out) :-
    K >= 0,
    list.index0(atom_frames(Bytes, 0), K, {_, FStart, FEnd, _, _}),
    cut_out(Bytes, FStart, FEnd, Out).

    % `insert_bytes`: `Octets` before atom `K`, counted from 0 by
    % `atom_frames`, or after the last atom when `K` is their number. They
    % need not be a frame. FAILS when `K` is past that number, or the walk
    % stops before the end of `Bytes`. Not re-sealed. `dsc_seal.py`'s
    % `insert_bytes`, by this module's own walk.
    %
:- pred bytes_inserted(list(uint8)::in, int::in, list(uint8)::in,
    list(uint8)::out) is semidet.

bytes_inserted(Bytes, K, Octets, Out) :-
    Frames = atom_frames(Bytes, 0),
    ( if list.last(Frames, {_, _, LastEnd, _, _}) then
        LastEnd = list.length(Bytes)
    else
        Bytes = []
    ),
    K >= 0,
    ( if list.index0(Frames, K, {_, Start, _, _, _}) then
        At = Start
    else
        K = list.length(Frames),
        At = list.length(Bytes)
    ),
    list.split_list(At, Bytes, Before, After),
    Out = Before ++ Octets ++ After.

    % `drop_call_operand` ([RDSC.4a.9.3]): in the one TerminalNode
    % (270) whose `rule_name` (field 3) is `Rule`, the first action (field 6)
    % that is an ACTION_CALL (kind, field 1, 0 or absent) whose `expr` (field
    % 2) is a `call` (Expr field 8) loses the LAST of the CallExpr's `args`
    % (field 2). The CallExpr, the Expr, the Action and the atom are re-framed
    % and the artefact re-sealed. No compiler writes a call its op does not
    % admit, so this is how a fixture hands a runtime one. FAILS when no or
    % several terminals realize `Rule`, none of its actions is such a call,
    % the call has no operand, or a body does not walk. `dsc_seal.py`'s
    % `drop_call_operand`, by this module's own walk.
    %
    % The artefact loads: [RDSC.4a.9.3] forbids a load-time operand check, so
    % this one is judged by the steps (`judge_run`), not by the load.
    %
:- pred call_operand_dropped(list(uint8)::in, string::in, list(uint8)::out)
    is semidet.

call_operand_dropped(Bytes, Rule, Out) :-
    RuleBytes = utf8_bytes(Rule),
    Terms = list.filter(
        ( pred({N, _, _, BS, BE}::in) is semidet :-
            N = 270,
            field_bytes(Bytes, BS, BE, 3, RuleBytes)
        ), atom_frames(Bytes, 0)),
    Terms = [{_, FStart, FEnd, BStart, BEnd}],
    list.split_list(BStart, Bytes, _, FromBody),
    list.split_list(BEnd - BStart, FromBody, Term, _),
    body_fields(Term, 0, list.length(Term), TFields),
    list.find_first_match(
        ( pred({N, _, _, A}::in) is semidet :-
            N = 6,
            field_varint_or_zero(A, 0, list.length(A), 1) = 0,
            field_bytes(A, 0, list.length(A), 2, X),
            field_bytes(X, 0, list.length(X), 8, _)
        ), tamper_spans(TFields, list.length(Term)), {_, S, E, Action}),
    field_bytes(Action, 0, list.length(Action), 2, Expr),
    field_bytes(Expr, 0, list.length(Expr), 8, Call),
    body_fields(Call, 0, list.length(Call), CFields),
    Args = list.filter(
        ( pred({N, _, _, _}::in) is semidet :- N = 2 ),
        tamper_spans(CFields, list.length(Call))),
    list.last(Args, {_, AStart, AEnd, _}),
    tamper_replace_span(Call, AStart, AEnd, [], Short),
    tamper_with_first(Expr, 8, Short, NewExpr),
    tamper_with_first(Action, 2, NewExpr, NewAction),
    tamper_replace_span(Term, S, E, tamper_delimited(6, NewAction), NewTerm),
    Inner = tamper_delimited(270, NewTerm),
    tamper_replace_span(Bytes, FStart, FEnd,
        [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner, Edited),
    reseal(Edited, Out).

    % A length-delimited field: its key, its length, its value.
    %
:- func tamper_delimited(int, list(uint8)) = list(uint8).

tamper_delimited(Field, Value) =
    varint_u8(Field * 8 + 2) ++ varint_u8(list.length(Value)) ++ Value.

    % `body_fields`' fields as {number, start, end, value}, each field's end
    % where the next one starts, the last's at `End`.
    %
:- func tamper_spans(list({int, int, list(uint8)}), int)
    = list({int, int, int, list(uint8)}).

tamper_spans([], _) = [].
tamper_spans([{N, S, V} | Rest], End) = [{N, S, E, V} | tamper_spans(Rest, End)] :-
    E = ( if Rest = [{_, Next, _} | _] then Next else End ).

    % `Body` with its first field `Field` replaced by the length-delimited
    % field holding `Value`. FAILS when the body does not walk or has none.
    %
:- pred tamper_with_first(list(uint8)::in, int::in, list(uint8)::in,
    list(uint8)::out) is semidet.

tamper_with_first(Body, Field, Value, Out) :-
    body_fields(Body, 0, list.length(Body), Fields),
    list.find_first_match(
        ( pred({N, _, _, _}::in) is semidet :- N = Field ),
        tamper_spans(Fields, list.length(Body)), {_, S, E, _}),
    tamper_replace_span(Body, S, E, tamper_delimited(Field, Value), Out).

    % `Bytes` with the bytes from `Start` up to `End` replaced by `New`.
    %
:- pred tamper_replace_span(list(uint8)::in, int::in, int::in,
    list(uint8)::in, list(uint8)::out) is semidet.

tamper_replace_span(Bytes, Start, End, New, Out) :-
    list.split_list(Start, Bytes, Before, _),
    list.split_list(End, Bytes, _, After),
    Out = Before ++ New ++ After.

    % `Bytes` with the bytes from `Start` up to `End` removed.
    %
:- pred cut_out(list(uint8)::in, int::in, int::in, list(uint8)::out)
    is semidet.

cut_out(Bytes, Start, End, Out) :-
    list.split_list(End, Bytes, UpToEnd, After),
    list.split_list(Start, UpToEnd, Before, _),
    Out = Before ++ After.

    % {atom number, frame start, frame end, body start, body end} of each
    % top-level atom, up to the first frame that does not walk:
    % `dsc_seal.py`'s `atom_frames`.
    %
:- func atom_frames(list(uint8), int) = list({int, int, int, int, int}).

atom_frames(Bytes, Pos) = Frames :-
    ( if
        list.index0(Bytes, Pos, 0x0Au8),
        byte_varint(Bytes, Pos + 1, 0, 0, OuterLen, Inner),
        End = Inner + OuterLen,
        byte_varint(Bytes, Inner, 0, 0, Key, LenAt),
        Key /\ 7 = 2,
        byte_varint(Bytes, LenAt, 0, 0, BodyLen, Body),
        Body + BodyLen =< End,
        End =< list.length(Bytes)
    then
        Frames = [{Key >> 3, Pos, End, Body, Body + BodyLen}
            | atom_frames(Bytes, End)]
    else
        Frames = []
    ).

    % The value of the first length-delimited field `Field` in the body from
    % `Pos` to `End`.
    %
:- pred field_bytes(list(uint8)::in, int::in, int::in, int::in,
    list(uint8)::out) is semidet.

field_bytes(Bytes, Pos, End, Field, Value) :-
    Pos < End,
    byte_varint(Bytes, Pos, 0, 0, Key, At),
    Wire = Key /\ 7,
    ( if Wire = 2 then
        byte_varint(Bytes, At, 0, 0, Len, VStart),
        ( if Key >> 3 = Field then
            list.split_list(VStart, Bytes, _, Rest),
            Value = list.take_upto(Len, Rest)
        else
            field_bytes(Bytes, VStart + Len, End, Field, Value)
        )
    else
        (
            Wire = 0,
            byte_varint(Bytes, At, 0, 0, _, Next)
        ;
            Wire = 1,
            Next = At + 8
        ;
            Wire = 5,
            Next = At + 4
        ),
        field_bytes(Bytes, Next, End, Field, Value)
    ).

    % The varint field `Field` of the body from `Start` to `End`, or 0 when
    % the body omits it, as proto3 reads an absent field.
    %
:- func field_varint_or_zero(list(uint8), int, int, int) = int.

field_varint_or_zero(Bytes, Start, End, Field) = V :-
    ( if
        varint_field_offset(Bytes, Start, End, Field, At),
        byte_varint(Bytes, At, 0, 0, V0, _)
    then
        V = V0
    else
        V = 0
    ).

    % `Edited` sealed as the compiler seals: the stored hash zeroed, the whole
    % artefact hashed, the digest written in [RDSC.3.6]. The hash is the
    % 32-byte field 7 of the first DscHeader (263) the walk of the frames
    % reaches (`sealed_hash_offset`), wherever it stands, since an edit can
    % put bytes before it [RCTS.1.2.21]. With none, there is no hash to
    % recompute, and `Edited` is what is loaded. `dsc_seal.py`'s
    % `seal`, by this module's own walk.
    %
:- pred reseal(list(uint8)::in, list(uint8)::out) is det.

reseal(Edited, Out) :-
    ( if sealed_hash_offset(Edited, At) then
        list.det_split_list(At, Edited, Before, Rest),
        list.det_split_list(32, Rest, _, After),
        Zeroed = Before ++ list.duplicate(32, 0u8) ++ After,
        Out = Before ++ ds.sha256.sha256(Zeroed) ++ After
    else
        Out = Edited
    ).

    % The offset of the 32 octets of the first DscHeader's field 7, the
    % first such field of 32 octets in its body. FAILS when the walk of the
    % frames reaches no DscHeader, or its body does not walk to one.
    %
:- pred sealed_hash_offset(list(uint8)::in, int::out) is semidet.

sealed_hash_offset(Bytes, At) :-
    list.find_first_match(
        ( pred({N, _, _, _, _}::in) is semidet :- N = 263 ),
        atom_frames(Bytes, 0), {_, _, _, BStart, BEnd}),
    body_fields(Bytes, BStart, BEnd, Fields),
    list.find_first_match(
        ( pred({F, _, V}::in) is semidet :- F = 7, list.length(V) = 32 ),
        Fields, {_, KeyAt, _}),
    byte_varint(Bytes, KeyAt, 0, 0, _, LenAt),
    byte_varint(Bytes, LenAt, 0, 0, _, At).

    % The offset of the body of the first top-level atom numbered `Field`.
    % Each atom is an outer field 1 (0x0A, length) holding one inner field:
    % the atom's number with wire type 2, a length, the body [RFCS.19.1].
    % `dsc_seal.py`'s `atom_body_offset`.
    %
:- pred atom_body_offset(list(uint8)::in, int::in, int::out) is semidet.

atom_body_offset(Bytes, Field, At) :-
    atom_body_offset_from(Bytes, Field, 0, At).

:- pred atom_body_offset_from(list(uint8)::in, int::in, int::in, int::out)
    is semidet.

atom_body_offset_from(Bytes, Field, Pos, At) :-
    list.index0(Bytes, Pos, 0x0Au8),
    byte_varint(Bytes, Pos + 1, 0, 0, OuterLen, Inner),
    End = Inner + OuterLen,
    byte_varint(Bytes, Inner, 0, 0, Key, LenAt),
    byte_varint(Bytes, LenAt, 0, 0, BodyLen, Body),
    ( if Key = Field * 8 + 2, BodyLen > 0, Body + BodyLen =< End then
        At = Body
    else
        atom_body_offset_from(Bytes, Field, End, At)
    ).

    % `add_schema_ref` ([RDSC.5.5.5]), as `runner.py` honours it through
    % `dsc_seal.add_slot_schema_ref`: `{"schema": S, "slot": N, "ref": R}`
    % gives the compiled artefact's one Slot atom (257) for S.N field 4,
    % `schema_ref` = R, at its place in ascending field order ([RFCS.19.5]),
    % re-frames the atom and re-seals the artefact. No compiler writes a
    % reference on a slot that is not a schema slot, so this is how a fixture
    % hands a runtime one. FAILS when there is not exactly one such Slot, when
    % it already carries field 4, or when the frames or its body do not walk.
    % The walk is this module's, not `dsc_seal.py`'s.
    %
:- pred schema_ref_added(json::in, list(uint8)::in, list(uint8)::out)
    is semidet.

schema_ref_added(j_object(Ms), Bytes, Out) :-
    lookup_member(Ms, "schema", SchemaJ), SchemaJ = j_string(Schema),
    lookup_member(Ms, "slot", SlotJ), SlotJ = j_string(Slot),
    lookup_member(Ms, "ref", RefJ), RefJ = j_string(Ref),
    list.length(members(Ms)) = 3,
    dsc_frames(Bytes, 0, Frames),
    Hits = list.filter_map(
        (func(Frame) = Hit is semidet :-
            Frame = {257, FStart, FBody, FEnd},
            body_fields(Bytes, FBody, FEnd, FFields),
            first_value(FFields, 1, utf8_bytes(Schema)),
            first_value(FFields, 2, utf8_bytes(Slot)),
            Hit = {FStart, FBody, FEnd, FFields}),
        Frames),
    Hits = [{Start, Body, End, Fields}],
    not first_value(Fields, 4, _),
    ( if
        list.find_first_match(
            (pred(F::in) is semidet :- F = {N, _, _}, N > 4), Fields, Later),
        Later = {_, C, _}
    then
        Cut = C
    else
        Cut = End
    ),
    list.split_list(Start, Bytes, Head, _),
    list.split_list(End, Bytes, _, Tail),
    list.split_list(Body, Bytes, _, FromBody),
    list.split_list(Cut - Body, FromBody, Lower, FromCut),
    list.split_list(End - Cut, FromCut, Upper, _),
    RefBytes = utf8_bytes(Ref),
    NewBody = Lower ++ [0x22u8] ++ varint_u8(list.length(RefBytes))
        ++ RefBytes ++ Upper,
    Inner = varint_u8(257 * 8 + 2) ++ varint_u8(list.length(NewBody))
        ++ NewBody,
    reseal(Head ++ [0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner
        ++ Tail, Out).

    % `add_compiled_code` ([RCTS.1.2.31], [RDSC.4c.3]), as `runner.py` honours
    % it through `dsc_seal.add_compiled_code`: `{"node": N}` appends, after
    % the compiled artefact's last atom, one CompiledCode atom (298) for each
    % of aot.proto's well-known `arch` values, in its order, each an RHS
    % (`kind` 3) for the TerminalNode whose `node_id` is N, with a body of 64
    % zero octets, and re-seals. No compiler writes the atom, so this is how a
    % fixture hands a runtime one. FAILS when the argument is of another shape, when not exactly
    % one TerminalNode carries the id, or when the frames do not walk to the
    % artefact's end. The walk is this module's, not `dsc_seal.py`'s.
    %
:- pred compiled_code_added(json::in, list(uint8)::in, list(uint8)::out)
    is semidet.

compiled_code_added(EditJ, Bytes, Out) :-
    compiled_code_appended(EditJ, Bytes, Edited),
    reseal(Edited, Out).

    % `compiled_code_added`'s edit, not re-sealed.
    %
:- pred compiled_code_appended(json::in, list(uint8)::in, list(uint8)::out)
    is semidet.

compiled_code_appended(EditJ, Bytes, Edited) :-
    add_compiled_code_shape(EditJ, Node),
    Frames = atom_frames(Bytes, 0),
    list.last(Frames, {_, _, LastEnd, _, _}),
    LastEnd = list.length(Bytes),
    Terms = list.filter(
        ( pred({N, _, _, BS, BE}::in) is semidet :-
            N = 270,
            field_varint_or_zero(Bytes, BS, BE, 1) = Node
        ), Frames),
    Terms = [_],
    Edited = Bytes ++ list.condense(list.map(compiled_code_atom(Node),
        ["amd64", "arm64", "rv64g", "rv64gc"])).

    % `add_compiled_code`'s shape, `{"node": N}` with N at least 1, and N.
    % `runner.py`'s `_add_compiled_code_shape`.
    %
:- pred add_compiled_code_shape(json::in, int::out) is semidet.

add_compiled_code_shape(j_object(Ms), Node) :-
    members(Ms) = ["node" - j_int(Node64)],
    Node64 >= 1i64,
    Node = int64.cast_to_int(Node64).

    % One framed CompiledCode atom: `arch`, `node_id`, `kind` CODE_KIND_RHS
    % and 64 zero octets of `body`, in ascending field order ([RFCS.19.5]).
    %
:- func compiled_code_atom(int, string) = list(uint8).

compiled_code_atom(Node, Arch) = [0x0Au8] ++ varint_u8(list.length(Inner))
        ++ Inner :-
    Body = tamper_delimited(1, utf8_bytes(Arch)) ++ t_int(2, Node)
        ++ t_int(3, 3) ++ tamper_delimited(4, list.duplicate(64, 0u8)),
    Inner = tamper_delimited(298, Body).

    % {atom number, frame start, body start, end} of each top-level atom, in
    % order. FAILS when a frame does not walk, or its body does not end where
    % the frame does.
    %
:- pred dsc_frames(list(uint8)::in, int::in, list({int, int, int, int})::out)
    is semidet.

dsc_frames(Bytes, Pos, Frames) :-
    ( if Pos >= list.length(Bytes) then
        Frames = []
    else
        list.index0(Bytes, Pos, 0x0Au8),
        byte_varint(Bytes, Pos + 1, 0, 0, OuterLen, Inner),
        End = Inner + OuterLen,
        byte_varint(Bytes, Inner, 0, 0, Key, LenAt),
        Key /\ 7 = 2,
        byte_varint(Bytes, LenAt, 0, 0, BodyLen, Body),
        Body + BodyLen = End,
        End =< list.length(Bytes),
        dsc_frames(Bytes, End, Rest),
        Frames = [{Key >> 3, Pos, Body, End} | Rest]
    ).

    % {field number, field start, value} of each field of the message body
    % from `Pos` to `End`, the value the bytes of a length-delimited field and
    % [] for any other. FAILS when the body does not walk.
    %
:- pred body_fields(list(uint8)::in, int::in, int::in,
    list({int, int, list(uint8)})::out) is semidet.

body_fields(Bytes, Pos, End, Fields) :-
    ( if Pos >= End then
        Pos = End,
        Fields = []
    else
        byte_varint(Bytes, Pos, 0, 0, Key, At),
        Wire = Key /\ 7,
        (
            Wire = 0,
            byte_varint(Bytes, At, 0, 0, _, Next),
            Value = []
        ;
            Wire = 1,
            Next = At + 8,
            Value = []
        ;
            Wire = 2,
            byte_varint(Bytes, At, 0, 0, Len, VStart),
            Next = VStart + Len,
            list.split_list(VStart, Bytes, _, FromV),
            list.split_list(Len, FromV, Value, _)
        ;
            Wire = 5,
            Next = At + 4,
            Value = []
        ),
        Next =< End,
        body_fields(Bytes, Next, End, Rest),
        Fields = [{Key >> 3, Pos, Value} | Rest]
    ).

    % The value of the first field numbered `Num`.
    %
:- pred first_value(list({int, int, list(uint8)})::in, int::in,
    list(uint8)::out) is semidet.

first_value(Fields, Num, Value) :-
    list.find_first_match((pred(F::in) is semidet :- F = {Num, _, _}),
        Fields, First),
    First = {_, _, Value}.

:- func varint_u8(int) = list(uint8).

varint_u8(N) =
    ( if N < 0x80 then
        [uint8.det_from_int(N)]
    else
        [uint8.det_from_int((N /\ 0x7F) \/ 0x80) | varint_u8(N >> 7)]
    ).

:- pred tamper_offset(string::in, list(uint8)::in, int::out) is semidet.

tamper_offset(Site, Bytes, At) :-
    ( if Site = "last_byte" then
        Bytes = [_ | _],
        At = list.length(Bytes) - 1
    else
        Site = "dsc_sha256",
        load_dsc(from_bytes(Bytes), loaded(P)),
        Stored = header(P) ^ dh_sha256,
        Stored = [_ | _],
        first_run(Bytes, Stored, 0, At)
    ).

    % The first index at which `Run` occurs in `Bytes`.
    %
:- pred first_run(list(uint8)::in, list(uint8)::in, int::in, int::out)
    is semidet.

first_run(Bytes, Run, I, At) :-
    ( if list.append(Run, _, Bytes) then
        At = I
    else
        Bytes = [_ | Rest],
        first_run(Rest, Run, I + 1, At)
    ).

    % `libds.h`'s code and libds's message, for the load refusals a fixture
    % names.
    %
:- pred libds_load_status(load_error::in, int::out, string::out) is semidet.

    % -504 is several refusals here, told apart by the clause, in one clause
    % so the switch on the kind stays semidet:
    %   * [RDSC.3.6]: the stored hash does not match;
    %   * [RDSC.11.3]: an expression the artefact does not state, or
    %     one nested deeper than 48. libds words its four shapes apart; this
    %     runtime refuses all four as one `lek_semantic` under the clause, so
    %     what the two share, and what a fixture's `message_contains` reads,
    %     is the clause's id.
libds_load_status(E, -504, Text) :-
    E ^ le_kind = lek_semantic,
    Clause = clause_id_string(E ^ le_clause),
    ( if Clause = "RDSC.3.6" then
        Text = "dsc: dsc_sha256 does not match the artefact — it changed "
            ++ "after the compiler sealed it (RDSC.3.6)"
    else if Clause = "RBND.1.3" then
        % [RBND.1.3]: the header's `capabilities` repeat a member,
        % are out of order or name a number no member has.
        Text = "dsc: the header's capabilities are not strictly ascending "
            ++ "over Capability's members (RBND.1.3)"
    else if Clause = "RDSC.4a.6" then
        % [RDSC.4a.6]: an AlphaNode whose `schema_name` is empty, a
        % body shape [RDSC.8.7] refuses before any name.
        Text = "rete_loader: an AlphaNode names no schema (RDSC.4a.6)"
    else if Clause = "RDSC.4a.6.1" then
        % [RDSC.4a.6.1]: a malformed AlphaTest, a body shape
        % [RDSC.8.7] refuses before any name. This runtime refuses every
        % shape the clause lists under the clause.
        Text = "rete_loader: a malformed AlphaTest (RDSC.4a.6.1)"
    else if Clause = "RDSC.9.10" then
        % [RDSC.9.10]: a NaN, quiet or signalling, held in a
        % `double` field. This runtime refuses each under the clause and
        % names the atom (`rdsc_9_5_names_atom`); libds words the four fields
        % apart, so the atom picks libds's wording.
        Text = rdsc_9_10_libds_text(E ^ le_atom)
    else if Clause = "RDSC.9.11" then
        % [RDSC.9.11]: a Slot whose `tolerance` is less than
        % zero, `-inf` included, refused in the walk as `handle_slot` refuses
        % it.
        Text = "dsc: Slot.tolerance is less than zero (RDSC.9.11)"
    else if Clause = "IRET.6.3" then
        % [RDSC.4a.6.1]'s one shape that is not the body's: an alpha REGEX
        % pattern that does not compile, which this runtime refuses as
        % [IRET.6.3]'s load-time compile.
        Text = "rete_loader: an alpha REGEX pattern does not compile "
            ++ "(IRET.6.3)"
    else
        Clause = "RDSC.11.3",
        Text = "rete_loader: an expression the artefact does not state, or "
            ++ "one nested deeper than 48 (RDSC.11.3)"
    ).
libds_load_status(E, -500,
        "dsc: truncated trailing atom — a rule bundle is not appended to "
            ++ "while read (RDSC.9.7)") :-
    E ^ le_kind = lek_truncated,
    E ^ le_offset = yes(_).
    % [RDSC.9.5]: a decode refusal names the atom, the byte
    % offset and the decoder's reason. The text between them is each
    % runtime's own; what the two share is the atom's message name before
    % " body", " at offset <N>", the frame's start in decimal, and ": " and
    % the reason after it, which are the parts a -503 fixture's
    % `message_contains` array reads.
    % [RDSC.8.7]: an atom names something no atom in the artefact
    % defines; libds's AlphaNode wording, which is the case a fixture drives.
libds_load_status(E, -506,
        "dsc: an AlphaNode names a schema no schema group in the artefact "
            ++ "declares (RDSC.8.7)") :-
    E ^ le_kind = lek_dangling.
    % [RDSC.11.1]: a node_id cross-reference names no node; libds's
    % wording for the TerminalNode's parent, the case a fixture drives.
libds_load_status(E, -602,
        "loader: TerminalNode parent_beta_id not found") :-
    E ^ le_kind = lek_retp_index_oob.
    % [RDSC.11.1]: an artefact whose first atom is not a
    % DscHeader, whatever its number and band, is not a `.dsc`.
libds_load_status(E, -501,
        "dsc: the first atom is not a DscHeader (RDSC.11.1)") :-
    E ^ le_kind = lek_bad_first_atom.
    % [RDSC.4a.3]: a node whose `node_id` is 0, the id reserved as
    % null, refused as its body is decoded and so before any name [RDSC.8.7].
libds_load_status(E, -601,
        "rete_loader: a node_id of 0, reserved as null (RDSC.4a.3)") :-
    E ^ le_kind = lek_retp_invalid.
    % [RDSC.4a.9.3]: a CallExpr whose op this runtime holds no
    % handler for where it stands. libds words it from `rete_loader.c`'s one
    % op check, which every CallExpr passes through, an action's `expr`
    % included.
libds_load_status(E, -604, "rete_loader: unknown builtin op in CALL expr") :-
    E ^ le_kind = lek_fn_not_found.
    % [RDSC.11.1]: a frame after the first whose `Atom` has no oneof
    % member ([RFCS.19.3]), which this runtime names as its own kind and libds
    % refuses as a malformed frame.
libds_load_status(E, -503, "dsc: malformed atom frame (RDSC.11.1)") :-
    E ^ le_kind = lek_empty_atom,
    clause_id_string(E ^ le_clause) = "RDSC.11.1".
    % [RDSC.11.1]: a frame after the first whose `Atom`'s field number
    % is in no band ([RFCS.16.3]), 0 or past 2047, which this runtime names as
    % its own kind and libds refuses in `handle_unknown_field`.
libds_load_status(E, -503,
        "dsc: an atom's field number is in no band (RDSC.11.1, RFCS.16.3)") :-
    E ^ le_kind = lek_malformed_field_number,
    clause_id_string(E ^ le_clause) = "RDSC.11.1".
    %
    % [RDSC.9.5]: a body holding a message field that is not repeated,
    % or `DscHeader.dsc_sha256`, more than once. libds's words, which name the
    % atom (`RDSC_9_5_REPEATED`, `dsc_verify_self_hash`) and gain the offset
    % in its walk. One clause for the kind, so the switch on it stays semidet.
libds_load_status(E, -503, Message) :-
    E ^ le_kind = lek_decode,
    E ^ le_offset = yes(Offset),
    Atom = ( if E ^ le_atom = yes(A) then A else "an atom" ),
    Clause = clause_id_string(E ^ le_clause),
    ( if Clause = "RDSC.11.1" then
        Reason = ( if E ^ le_reason = yes(R) then ": " ++ R else "" ),
        Message = "dsc: " ++ Atom ++ " body failed to decode at offset "
            ++ string.int_to_string(Offset) ++ Reason
    else
        Clause = "RDSC.9.5",
        What = ( if Atom = "DscHeader" then "dsc_sha256"
                 else "a message field that is not repeated" ),
        Message = "dsc: " ++ Atom ++ " body holds " ++ What
            ++ " more than once at offset " ++ string.int_to_string(Offset)
            ++ " (RDSC.9.5)"
    ).

    % libds's message for a NaN in each of [RDSC.9.10]'s four fields, by the
    % atom this runtime's refusal names: an `AlphaNode`'s literal, a `Slot`'s
    % tolerance, an `initial:` item's `TestSlotLiteral`, and otherwise an
    % `Expr` (a `BetaNode`'s or a `TerminalNode`'s).
    %
:- func rdsc_9_10_libds_text(maybe(string)) = string.

rdsc_9_10_libds_text(Atom) = Text :-
    ( if Atom = yes("AlphaNode") then
        Text = "rete_loader: AlphaLiteral.float_val is a NaN (RDSC.9.10)"
    else if Atom = yes("Slot") then
        Text = "dsc: Slot.tolerance is a NaN (RDSC.9.10)"
    else if ( Atom = yes("InitialFact") ; Atom = yes("InitialCacheSeed") )
    then
        Text = "dsc: TestSlotLiteral.f_val is a NaN (RDSC.9.10)"
    else
        Text = "rete_loader: Expr.lit_float is a NaN (RDSC.9.10)"
    ).

    % The fixture's result, and the names of the rules its run fired, in
    % order, where its kind records them (`records_firings`).
    %
:- func run_expectation(string, json_members, program)
    = {behave_result, maybe(list(string))}.

run_expectation(Kind, Expect, P) = {Result, Fired} :-
    ( if Kind = "runtime_fact_count" then
        {Result, Fired} = run_fact_count(Expect, P)
    else if Kind = "hash_order_independence" then
        Result = run_hash_order(Expect, P),
        Fired = no
    else if Kind = "runtime_error" then
        Result = run_runtime_error(Expect, P),
        Fired = no
    else if Kind = "clone_determinism" then
        Result = run_clone_determinism(Expect, P),
        Fired = no
    else if Kind = "adapter_mock" then
        {Result, Fired} = run_adapter_mock(Expect, P)
    else if Kind = "pbf_framing" then
        Result = pbf_framing_result(Kind, Expect),
        Fired = no
    else
        E1 = steps_engine(Kind, Expect, P),
        Steps = array_member(Expect, "steps"),
        ( if
            Kind = "replay_determinism",
            lookup_member(Expect, "tamper", _)
        then
            % [RCTS.1.2.21]: the run must halt, and the step during
            % which it does is the run's outcome, as `runner.py`'s
            % `_replay_through_libds_rfcs` takes it.
            run_halting_steps(P, Steps, E1, E, map.init, _, [], RevEffects,
                Status0),
            RevPumpStatuses = [],
            Status = ( if Status0 = run_ok, engine_halted(E) = no then
                    run_refused(refused("replay_determinism: expect.tamper, "
                        ++ "but the run did not halt the engine, so there is "
                        ++ "no halted run to replay ([RCTS.1.2.21])"))
                else
                    Status0 )
        else
            run_steps_statuses(P, Steps, E1, E, map.init, _, [], RevEffects,
                [], RevPumpStatuses, Status)
        ),
        PumpStatuses = list.reverse(RevPumpStatuses),
        Stamped = list.reverse(RevEffects),
        Effects = list.condense(list.map(stamped_effects, Stamped)),
        (
            Status = run_unsupported(Why),
            Result = behave_result(bo_unsupported, Kind, Why),
            Fired = no
        ;
            % pyds raises here, and `run_test` fails the fixture
            % ([RCTS.1.2.28]).
            Status = run_refused(Refusal),
            Result = behave_result(bo_fail, Kind, refusal_text(Refusal)),
            Fired = no
        ;
            Status = run_ok,
            IT = engine_interns(E),
            Fired = ( if records_firings(Kind) then
                        yes(list.filter_map(fire_name(IT), Effects))
                    else
                        no ),
            Kinds = list.filter_map(event_kind, Effects),
            ( if Kind = "temporal_sequence" then
                Result = fact_count_result(Kind, Expect, E)
            else if Kind = "header_field_eq" then
                Result = header_result(Kind, Expect, E)
            else if Kind = "rfcs_artefact_strip" then
                Result = artefact_strip_result(Kind, P, E, Stamped)
            else if Kind = "rfcs_roundtrip" then
                Result = rfcs_roundtrip_result(Kind, Expect, P, E, Stamped,
                    Kinds)
            else if Kind = "replay_determinism" then
                % A pump's status is judged as `runner.py` judges it there:
                % stated by the field, or the fixture fails ([RCTS.1.2.30]).
                Result = pump_statuses_result(Kind, Expect, PumpStatuses,
                    replay_determinism_result(Kind, Expect, P, E, Stamped))
            else if Kind = "replay_refused" then
                Result = replay_refused_result(Kind, Expect, P, E, Stamped)
            else if Kind = "field_order" then
                Result = field_order_result(Kind, Expect, P, E, Stamped)
            else if Kind = "introspection_assert" then
                Result = introspection_result(Kind, Expect, P, E)
            else if Kind = "event_seq_monotonic" then
                Result = seq_monotonic_result(Kind, Expect, Stamped)
            else if Kind = "rule_fire_order" then
                Result = compare_lists(Kind,
                    string_array(array_member(Expect, "expected_rule_names")),
                    list.filter_map(fire_name(IT), Effects))
            else if Kind = "log_message_sequence" then
                Result = compare_lists(Kind,
                    string_array(array_member(Expect, "expected_messages")),
                    list.filter_map(log_message, Effects))
            else if Kind = "adapter_calls" then
                Result = pump_statuses_result(Kind, Expect, PumpStatuses,
                    adapter_calls_result(Kind, Expect, IT, Effects))
            else if Kind = "adapter_cache_sets" then
                Result = cache_sets_result(Kind, Expect, Effects)
            else if Kind = "adapter_cache_deletes" then
                Result = compare_lists(Kind,
                    string_array(array_member(Expect, "expected_keys")),
                    list.filter_map(cache_deleted, Effects))
            else if Kind = "event_sequence_strict" then
                Result = compare_lists(Kind,
                    string_array(array_member(Expect, "expected_kinds")),
                    Kinds)
            else if Kind = "event_kinds_forbidden" then
                Forbidden = string_array(array_member(Expect,
                    "forbidden_kinds")),
                Seen = list.filter(
                    (pred(K::in) is semidet :- list.member(K, Kinds)),
                    Forbidden),
                (
                    Seen = [],
                    Result = behave_result(bo_pass, Kind, "")
                ;
                    Seen = [_ | _],
                    Result = behave_result(bo_fail, Kind,
                        "forbidden kinds appeared: ["
                            ++ string.join_list(", ", Seen) ++ "]")
                )
            else
                Want = string_array(array_member(Expect, "expected_kinds")),
                Projected = projection(Want, Kinds),
                ( if Projected = Want then
                    Result = behave_result(bo_pass, Kind, "")
                else
                    Result = behave_result(bo_fail, Kind,
                        "the stream's events of the stated kinds are ["
                            ++ string.join_list(", ", Projected)
                            ++ "], want [" ++ string.join_list(", ", Want)
                            ++ "]; whole stream ["
                            ++ string.join_list(", ", Kinds) ++ "]")
                )
            )
        )
    ).

    % The live fact count against `fact_count_after`.
    %
:- func fact_count_result(string, json_members, engine) = behave_result.

fact_count_result(Kind, Expect, E) = Result :-
    ( if int_member(Expect, "fact_count_after", Want) then
        Got = engine_fact_count(E),
        ( if Got = Want then
            Result = behave_result(bo_pass, Kind, "")
        else
            Result = behave_result(bo_fail, Kind,
                string.format("fact_count_after: want %d got %d",
                    [i(Want), i(Got)]))
        )
    else
        Result = behave_result(bo_unsupported, Kind,
            "no integer `fact_count_after`")
    ).

    % `header_field_eq`, as `runner.py` judges it: after the steps,
    % each of `checks` names a field of the session header ([RFCS.4],
    % [LFST.4]) and one assertion, `equals` (Python `==`), `present` (the
    % value's truth, against the truth of the wanted value) or `byte_len` (a
    % bytes field's length). The first check that fails is the detail.
    %
    % The fields are pyds's names for `ds_engine_get_session_header`:
    % `ds_version`, `session_id`, `tier_id` and `dsc_hash`, read from
    % `ds.engine.session_header`. `dsc_hash` is bytes, the rest strings.
    %
:- type header_value
    --->    hv_text(string)
    ;       hv_bytes(list(uint8)).

:- func header_result(string, json_members, engine) = behave_result.

header_result(Kind, Expect, E) = Result :-
    Header = session_header(E),
    Fields = [
        "ds_version" - hv_text(Header ^ sm_ds_version),
        "dsc_hash" - hv_bytes(Header ^ sm_dsc_hash),
        "session_id" - hv_text(Header ^ sm_session),
        "tier_id" - hv_text(Header ^ sm_tier)
    ],
    Checks = list.filter_map(as_object, array_member(Expect, "checks")),
    ( if list.find_first_map(header_check_failure(Fields), Checks, Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else
        Result = behave_result(bo_pass, Kind, "")
    ).

    % Succeeds with the failure when one check does not hold.
    %
:- pred header_check_failure(assoc_list(string, header_value)::in,
                             json_members::in, string::out) is semidet.

header_check_failure(Fields, Check, Why) :-
    Field = ( if lookup_member(Check, "field", j_string(F)) then F else "" ),
    ( if assoc_list.search(Fields, Field, Got) then
        ( if lookup_member(Check, "equals", Want) then
            not header_equals(Got, Want),
            Why = "header `" ++ Field ++ "`: want " ++ string.string(Want)
                ++ ", got " ++ string.string(Got)
        else if lookup_member(Check, "present", WantJ) then
            IsPresent = header_truthy(Got),
            WantPresent = json_truthy(WantJ),
            IsPresent \= WantPresent,
            Why = "header `" ++ Field ++ "` present="
                ++ string.string(IsPresent) ++ ", want present="
                ++ string.string(WantPresent)
        else if lookup_member(Check, "byte_len", LenJ) then
            ( if Got = hv_bytes(Bytes) then
                not (
                    LenJ = j_int(Len),
                    int64.cast_to_int(Len) = list.length(Bytes)
                ),
                Why = "header `" ++ Field ++ "` byte_len: want "
                    ++ string.string(LenJ) ++ ", got "
                    ++ string.int_to_string(list.length(Bytes))
            else
                Why = "header `" ++ Field
                    ++ "` byte_len check needs bytes, got "
                    ++ string.string(Got)
            )
        else
            Why = "header check for `" ++ Field ++ "` has no assertion "
                ++ "(need equals / present / byte_len)"
        )
    else
        Why = "header field `" ++ Field ++ "` absent from session header "
            ++ "(have: " ++ string.join_list(", ", assoc_list.keys(Fields))
            ++ ")"
    ).

    % Python `==` between a header value and a decoded JSON value: a string
    % equals only the same string; bytes equal no JSON value at all.
    %
:- pred header_equals(header_value::in, json::in) is semidet.

header_equals(hv_text(S), j_string(S)).

    % Python truth: a string or bytes is true when non-empty.
    %
:- func header_truthy(header_value) = bool.

header_truthy(hv_text(S)) = ( if S = "" then no else yes ).
header_truthy(hv_bytes(Bs)) = ( if Bs = [] then no else yes ).

    % Python truth of a decoded JSON value.
    %
:- func json_truthy(json) = bool.

json_truthy(J) =
    ( if
        ( J = j_null
        ; J = j_bool(no)
        ; J = j_int(0i64)
        ; J = j_float(0.0)
        ; J = j_string("")
        ; J = j_array([])
        ; J = j_object(O), members(O) = []
        )
    then no
    else yes ).

    % The stream's kinds cut down to the kinds `Want` names, in stream order:
    % `runner.py`'s `_event_sequence_projection`. `event_sequence` passes when
    % this is `Want` ([RCTS.1.2.10]).
    %
:- func projection(list(string), list(string)) = list(string).

projection(Want, Kinds) =
    list.filter((pred(K::in) is semidet :- list.member(K, Want)), Kinds).

    % `event_seq_monotonic`, as `runner.py` evaluates it: optionally narrow
    % to one `filter_kind`; the `seq`s must strictly increase; there must be
    % at least `min_events`; with `expected_seq_step` each consecutive pair
    % differs by exactly that; with `expected_clocks` the first N events'
    % `clock_ns` equal the list.
    %
    % `seq` is `ds.effect.record`'s: every stream event in emission order,
    % contiguous from zero (`stream_seq.tla`), an event with no harness kind
    % name included.
    %
:- func seq_monotonic_result(string, json_members, list(stamped))
    = behave_result.

seq_monotonic_result(Kind, Expect, Stamped) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    All = list.reverse(RevAll),
    ( if lookup_member(Expect, "filter_kind", FJ), FJ = j_string(Filter) then
        View = list.filter(
            (pred({_, _, Ev}::in) is semidet :- stream_kind(Ev, Filter)),
            All)
    else
        View = All
    ),
    Seqs = list.map((func({S, _, _}) = uint64.cast_to_int(seq_value(S))),
        View),
    Clocks = list.map((func({_, C, _}) = uint64.cast_to_int(instant_ns(C))),
        View),
    Min = ( if int_member(Expect, "min_events", M) then M else 1 ),
    ( if not strictly_increasing(Seqs) then
        Result = behave_result(bo_fail, Kind, "seq not strictly increasing")
    else if list.length(Seqs) < Min then
        Result = behave_result(bo_fail, Kind,
            string.format("too few events captured: %d < %d",
                [i(list.length(Seqs)), i(Min)]))
    else if
        int_member(Expect, "expected_seq_step", Step),
        not steps_by(Step, Seqs)
    then
        Result = behave_result(bo_fail, Kind,
            string.format("seq step is not +%d: %s",
                [i(Step), s(string.string(Seqs))]))
    else if
        lookup_member(Expect, "expected_clocks", WantJ),
        WantJ = j_array(WantEs),
        list.map((pred(J::in, N::out) is semidet :- J = j_int(N)), WantEs,
            Want),
        list.take_upto(list.length(Want), Clocks, GotClocks0),
        GotClocks = list.map(int64.from_int, GotClocks0),
        GotClocks \= Want
    then
        Result = behave_result(bo_fail, Kind,
            "expected_clocks prefix mismatch: want "
                ++ string.string(Want) ++ ", got "
                ++ string.string(GotClocks))
    else
        Result = behave_result(bo_pass, Kind, "")
    ).

    % `replay_determinism` [LFST.9, LCON.2.2.1]: record a session, replay it
    % into a fresh engine, and the replay must reproduce the recorded stream.
    %
    % Through this runtime's own recording: the run is encoded to RFCS
    % (`ds.rfcs`), decoded, and replayed by `ds.replay`.
    %
    % Compared: both engines' event streams with clock ticks set aside, and
    % their final clocks. A recording drops a tick that moved the clock
    % nowhere, so the replay may have one fewer; the end clock says every
    % real move was reproduced.
    %
    % `min_events` counts the recorded run's events; `min_rule_fires` counts
    % the rule fires the replay re-derived.
    %
:- func replay_determinism_result(string, json_members, program, engine,
    list(stamped)) = behave_result.

replay_determinism_result(Kind, Expect, P, EA, Stamped) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    All = list.reverse(RevAll),
    Records = list.map((func({S, _, Ev}) = {S, Ev}), All),
    Meta = session_header(EA),
    Ctx = rfcs_ctx(schemas(P), engine_interns(EA)),
    % The host's seeds are in the recording ([RFCS.26.1]), and the replaying
    % engine is given nothing else ([RFCS.26.2]).
    encode_recording(Meta, Ctx, from_ns(0u64), prelude_seeds(EA),
        list.map(record_event, Records), Bytes, Unencodable),
    Min = ( if int_member(Expect, "min_events", M) then M else 0 ),
    ( if list.length(Records) < Min then
        Result = behave_result(bo_fail, Kind,
            string.format("recorded too few events: %d < %d",
                [i(list.length(Records)), i(Min)]))
    else if Unencodable = [_ | _] then
        Result = behave_result(bo_unsupported, Kind,
            "the run emitted events the recorder cannot encode: "
                ++ string.string(Unencodable))
    else if rcts_1_2_24_offset(Expect) = offset_refused(Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else if
        rcts_1_2_24_offset(Expect) = offset(OffsetN1),
        not timetags_offset(OffsetN1, Bytes, _)
    then
        Result = behave_result(bo_fail, Kind,
            "expect.timetag_offset, but the recording carries no nonzero "
                ++ "timetag to offset ([RCTS.1.2.24])")
    else
        % [RCTS.1.2.24]: a `timetag` is stream-local and compared by
        % its pairing ([LFST.9.3.6]), so an offset recording must replay as
        % the recording does.
        ReplayBytes = ( if
                rcts_1_2_24_offset(Expect) = offset(OffsetN),
                timetags_offset(OffsetN, Bytes, Renamed)
            then Renamed
            else Bytes ),
        decode_stream(from_bytes(ReplayBytes), init_interns, Decoded),
        (
            Decoded = decode_failed(Clause, Offset),
            Result = behave_result(bo_fail, Kind,
                string.format("the recording does not decode: %s at %d",
                    [s(Clause), i(Offset)]))
        ;
            Decoded = unannounced_schema(_, USeq, UOffset),
            Result = behave_result(bo_fail, Kind,
                string.format("the recording's FactAssert at seq %s (byte %d) "
                    ++ "names a schema no SchemaDef announced ([RFCS.5.4])",
                    [s(string.string(USeq)), i(UOffset)]))
        ;
            Decoded = decoded(DS),
            engine_use_mock_clock(init_engine(P), EB0),
            replay_stream(P, DS, Steps, EB0, EB),
            Replayed = list.condense(list.map(replay_step_effects, Steps)),
            WantEvents = non_tick_events(list.condense(
                list.map(stamped_effects, Stamped))),
            GotEvents = non_tick_events(Replayed),
            ( if list.last(Steps, unknown_schema(SchemaSeq)) then
                Result = behave_result(bo_fail, Kind,
                    "the replay met a schema the program does not declare, at "
                        ++ "seq " ++ string.string(SchemaSeq))
            else if list.last(Steps, unknown_fact_id(RetractSeq)) then
                Result = behave_result(bo_fail, Kind,
                    "the replay met a FactRetract of a fact no earlier atom "
                        ++ "carries, at seq " ++ string.string(RetractSeq))
            else if Steps = [recording_incomplete(First)] then
                Result = behave_result(bo_fail, Kind,
                    "the replay refused the recording: its first event has seq "
                        ++ string.string(First) ++ ", not 0")
            else if Steps = [binding_refused(Code, Detail)] then
                Result = behave_result(bo_fail, Kind,
                    "the replay refused the recording's binding ("
                        ++ string.from_int(Code) ++ "): " ++ Detail)
            else if
                list.find_first_match(
                    (pred(St::in) is semidet :- St = diverged(_)), Steps,
                    diverged(DivSeq))
            then
                Result = behave_result(bo_fail, Kind,
                    "the replay parted from the recording at seq "
                        ++ string.string(DivSeq)
                        ++ " (an ExternalAssert or a compare-class atom)")
            else if WantEvents \= GotEvents then
                Result = behave_result(bo_fail, Kind,
                    first_divergence(WantEvents, GotEvents, 0))
            else if engine_halted(EA) \= engine_halted(EB) then
                % [RFCS.6.7]: a halted run's replay reproduces the
                % halt and reaches the end of the recording, leaving the
                % replaying engine halted by the same fault; a run that did
                % not halt leaves neither halted.
                Result = behave_result(bo_fail, Kind,
                    "the run's halt latch holds "
                        ++ string.string(engine_halted(EA))
                        ++ ", the replay's "
                        ++ string.string(engine_halted(EB))
                        ++ " ([RFCS.6.7])")
            else if engine_now(EA) \= engine_now(EB) then
                Result = behave_result(bo_fail, Kind,
                    "final clocks differ: recorded "
                        ++ string.string(instant_ns(engine_now(EA)))
                        ++ ", replayed "
                        ++ string.string(instant_ns(engine_now(EB))))
            else if
                int_member(Expect, "min_rule_fires", MinFires),
                Fires = list.length(list.filter(
                    (pred(Ev::in) is semidet :- Ev = se_fire_begin(_)),
                    GotEvents)),
                Fires < MinFires
            then
                Result = behave_result(bo_fail, Kind,
                    string.format("the replay re-derived %d rule fire(s), "
                        ++ "fewer than %d", [i(Fires), i(MinFires)]))
            else
                Result = behave_result(bo_pass, Kind, "")
            )
        )
    ).

    % `replay_refused` [RCTS.1.2.18], as `runner.py`'s `_run_replay_refused`
    % checks it: the run is encoded to RFCS (`ds.rfcs`), altered by the
    % fixture's `mutation` (`stream_mutated`), decoded and replayed
    % (`ds.replay`). It passes when the unaltered recording replays with no
    % refusal and the altered one ends at a refusal whose
    % `replay_refusal_code` is the fixture's `code` -- the code libds's
    % replayer returns for the same atom.
    %
    % `late_start: N` alters when the recording begins instead: the records
    % of the first N steps are numbered and left out, so the altered
    % recording's first event keeps the `seq` the run gave it, which is not 0
    % ([LTIM.2.8.5]), as libds's recorder attached after those steps writes it.
    %
    % The header is the engine's own (`ds.engine.session_header`): the binding
    % tuple copied from the program's header ([RBND.3.1]), as libds's recorder
    % writes it, so `unknown_capability` has the program's `capabilities` to
    % alter.
    %
:- func replay_refused_result(string, json_members, program, engine,
    list(stamped)) = behave_result.

replay_refused_result(Kind, Expect, P, EA, Stamped) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    Records = list.map((func({S, _, Ev}) = {S, Ev}), list.reverse(RevAll)),
    Meta = session_header(EA),
    Ctx = rfcs_ctx(schemas(P), engine_interns(EA)),
    encode_recording(Meta, Ctx, from_ns(0u64), prelude_seeds(EA),
        list.map(record_event, Records), Bytes, Unencodable),
    WantCode =( if lookup_member(Expect, "code", CJ), CJ = j_string(C)
                 then C else "" ),
    Late = late_start_field(Expect),
    ( if Unencodable = [_ | _] then
        Result = behave_result(bo_unsupported, Kind,
            "the run emitted events the recorder cannot encode: "
                ++ string.string(Unencodable))
    else if Late = late_malformed(Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else if Late = late_start(N) then
        ( if late_records(Kind, P, Expect, N, Stamped, LateRecords) then
            % No `CacheSeed`: a recorder attached after the first event
            % writes none ([RFCS.26.1]).
            encode_stream(Meta, Ctx, from_ns(0u64), LateRecords, LateBytes, _),
            Result = refused_against(Kind, P, init_engine(P), Bytes,
                LateBytes, WantCode, "late start")
        else
            Result = behave_result(bo_fail, Kind,
                "the " ++ string.int_to_string(N) ++ " step(s) before "
                    ++ "`late_start` put no event on the stream, so the "
                    ++ "recording would begin at seq 0")
        )
    else if
        Late = reader_cache_cap,
        lookup_member(Expect, "replay_cache_cap", CapJ)
    then
        % [RCTS.1.2.18]: the run's own recording, replayed into an
        % engine with cache bounds the recording engine and the control did
        % not have ([RFCS.26.2]), set as `runtime_error`'s `cache_cap` sets
        % them (`with_cache_cap`).
        Result = refused_against(Kind, P,
            with_cache_cap(object(["cache_cap" - CapJ]), init_engine(P)),
            Bytes, Bytes, WantCode, "replay cache cap")
    else if
        lookup_member(Expect, "mutation", MJ),
        stream_mutated(MJ, Bytes, Altered)
    then
        Result = refused_against(Kind, P, init_engine(P), Bytes, Altered,
            WantCode, "mutation")
    else
        Result = behave_result(bo_fail, Kind,
            "the mutation names no member of [RCTS.1.2.18]'s set or has no "
                ++ "site in the recording")
    ).

    % The unaltered recording must replay with no refusal into a fresh engine,
    % and the altered one, into `Reader`, be refused with `WantCode`; `What`
    % names the alteration.
    %
:- func refused_against(string, program, engine, list(uint8), list(uint8),
    string, string) = behave_result.

refused_against(Kind, P, Reader, Bytes, Altered, WantCode, What) = Result :-
    ( if replay_refusal_in(P, init_engine(P), Bytes, Control) then
        Result = behave_result(bo_fail, Kind,
            "the UNALTERED recording was refused too (" ++ Control
                ++ "), so the refusal cannot be the " ++ What ++ "'s")
    else if replay_refusal_in(P, Reader, Altered, Got) then
        ( if Got = WantCode then
            Result = behave_result(bo_pass, Kind, "")
        else
            Result = behave_result(bo_fail, Kind,
                "want status " ++ WantCode ++ ", got " ++ Got)
        )
    else
        Result = behave_result(bo_fail, Kind,
            "the altered recording replayed without refusal")
    ).

    % [RCTS.1.2.18]'s alteration, read as `runner.py`'s `_late_start` reads
    % it: a `mutation`, a `late_start` step count from 1 to one less than the
    % number of steps, a `replay_cache_cap` of `cache_cap`'s shape, or
    % malformed -- more or fewer than one of the three, or one of another
    % type.
    %
:- type late_start_field
    --->    no_late_start
    ;       late_start(int)
    ;       reader_cache_cap
    ;       late_malformed(string).

:- func late_start_field(json_members) = late_start_field.

late_start_field(Expect) = Field :-
    Steps = list.length(array_member(Expect, "steps")),
    Given = list.filter(
        (pred(F::in) is semidet :- lookup_member(Expect, F, _)),
        ["mutation", "late_start", "replay_cache_cap"]),
    ( if Given \= [_] then
        Field = late_malformed("not exactly one of `mutation`, `late_start` "
            ++ "and `replay_cache_cap`: " ++ string.string(Given))
    else if Given = ["late_start"] then
        ( if
            int_member(Expect, "late_start", N),
            N >= 1,
            N < Steps
        then
            Field = late_start(N)
        else
            Field = late_malformed("`late_start` is not an integer from 1 to "
                ++ string.int_to_string(Steps - 1)
                ++ ", one less than the number of steps")
        )
    else if Given = ["replay_cache_cap"] then
        ( if
            lookup_member(Expect, "replay_cache_cap", CapJ),
            CapJ = j_object(Cap),
            list.all_true(cache_cap_member, members(Cap))
        then
            Field = reader_cache_cap
        else
            Field = late_malformed("`replay_cache_cap` is not an object of "
                ++ "`keys` and `bytes`, non-negative integers")
        )
    else
        Field = no_late_start
    ).

    % [RCTS.1.2.18]: `expect.replay_cache_cap` is `replay_refused`'s alone,
    % and a fixture of any other kind carrying it fails, as `runner.py`'s
    % `_replay_cache_cap_misplaced` fails it.
    %
:- func replay_cache_cap_placed(string, json_members, behave_result)
    = behave_result.

replay_cache_cap_placed(Kind, Expect, Result0) =
    ( if
        Kind \= "replay_refused",
        lookup_member(Expect, "replay_cache_cap", _)
    then
        behave_result(bo_fail, Kind, "expect.replay_cache_cap is "
            ++ "`replay_refused`'s alone ([RCTS.1.2.18]); this fixture's kind "
            ++ "is `" ++ Kind ++ "`")
    else
        Result0
    ).

    % The records a recorder attached after the first `N` steps writes: the
    % run's own records, numbered from the run's start, less those the first
    % `N` steps made. Those steps are run again, from the start every driver
    % takes (`steps_engine`), to count the stamped entries they push; the
    % engine is a value, so the count is the run's own. Fails when they made
    % no record.
    %
:- pred late_records(string::in, program::in, json_members::in, int::in,
    list(stamped)::in, list({seq, stream_event})::out) is semidet.

late_records(Kind, P, Expect, N, Stamped, Late) :-
    list.take_upto(N, array_member(Expect, "steps"), Early),
    run_steps(P, Early, steps_engine(Kind, Expect, P), _, map.init, _, [],
        RevEarly, Status),
    Status = run_ok,
    list.split_upto(list.length(RevEarly), Stamped, EarlyStamped,
        LateStamped),
    list.foldl2(number_step, EarlyStamped, init_recorder, R, [], RevE),
    RevE = [_ | _],
    list.foldl2(number_step, LateStamped, R, _, [], RevLate),
    Late = list.map((func({S, _, Ev}) = {S, Ev}), list.reverse(RevLate)).

    % Succeeds with how a recording was refused: the replay's refusal code as
    % a string, or, for a recording that does not decode, the clause the
    % decoder names. Fails for one that replays with no refusal.
    %
:- pred replay_refusal(program::in, list(uint8)::in, string::out) is semidet.

replay_refusal(P, Bytes, Why) :-
    replay_refusal_in(P, init_engine(P), Bytes, Why).

    % `replay_refusal`, replayed into `E00` on the mock clock: an engine with
    % `replay_cache_cap`'s bounds ([RCTS.1.2.18]), or a fresh one.
    %
:- pred replay_refusal_in(program::in, engine::in, list(uint8)::in,
    string::out) is semidet.

replay_refusal_in(P, E00, Bytes, Why) :-
    decode_stream(from_bytes(Bytes), init_interns, Decoded),
    (
        Decoded = decode_failed(Clause, Offset),
        ( if Clause = "RBND.1.3" then
            % [RBND.1.3]: a malformed header `capabilities` list is
            % refused where the header is read. libds's
            % `ds_rfcs_decode_header` refuses it with DS_ERR_PARSE, the code
            % a fixture names; this decoder names the clause.
            Why = "-100"
        else
            Why = string.format("does not decode: %s at %d",
                [s(Clause), i(Offset)])
        )
    ;
        Decoded = decoded(DS),
        engine_use_mock_clock(E00, E0),
        replay_stream(P, DS, Steps, E0, _),
        list.last(Steps, Last),
        Code = replay_refusal_code(Last),
        Why = string.int_to_string(Code)
    ;
        % [RFCS.5.4]'s first case: the reader stopped at a FactAssert
        % no SchemaDef announced, and the replay delivers what came before it
        % and refuses it there, as libds's replay does -- -101, unless a
        % refusal before it came first.
        Decoded = unannounced_schema(DS, Seq, _),
        engine_use_mock_clock(init_engine(P), E0),
        replay_unannounced(P, DS, Seq, Steps, E0, _),
        list.last(Steps, Last),
        Code = replay_refusal_code(Last),
        Why = string.int_to_string(Code)
    ).

    % A fault `fault_node` and `drop_fault` take: its atom number and `node_id`.
    %
:- pred fault_atom(string::in, int::out, int::out) is semidet.

fault_atom("TypeError", 328, 1).
fault_atom("ComputationError", 325, 7).

    % FactPublish's two names ([RFCS.27.1]), by the field each is, for
    % `publish_name`. `stream_edit.py`'s `PUBLISH_NAME_FIELDS`.
    %
:- pred publish_name_field(string::in, int::out) is semidet.

publish_name_field("schema_name", 1).
publish_name_field("rule_name", 2).

    % The first atom numbered `Num`: where its frame starts and ends, and its
    % body's start. `From` is where the first of `Atoms` starts.
    %
:- pred first_frame(list({int, int, int})::in, int::in, int::in, int::out,
    int::out, int::out) is semidet.

first_frame([{ANum, AStart, AEnd} | Atoms], Num, From, FrameStart, Start, End) :-
    ( if ANum = Num then
        FrameStart = From,
        Start = AStart,
        End = AEnd
    else
        first_frame(Atoms, Num, AEnd, FrameStart, Start, End)
    ).

    % [RCTS.1.2.18]'s closed set of alterations, as `stream_edit.py` makes
    % them, by this module's own walk of the frames (`stream_atoms`,
    % `dsc_frames`). Each but `drop_schema_def`, `drop_fault` and
    % `append_engine_error` keeps every length; `seed_after_event` moves a frame
    % whole, and no other moves one. Those three remove or add whole atoms.
    %
:- pred stream_mutated(json::in, list(uint8)::in, list(uint8)::out)
    is semidet.

stream_mutated(j_object(O), Bytes, Out) :-
    Members = members(O),
    ( if Members = ["from" - j_string(From), "op" - j_string("rename_schema"),
                    "to" - j_string(To)] then
        FromBytes = utf8_bytes(From),
        ToBytes = utf8_bytes(To),
        FromBytes = [_ | _],
        list.same_length(FromBytes, ToBytes),
        FromBytes \= ToBytes,
        replace_all(FromBytes, ToBytes, Bytes, Out, no, yes)
    else if
        Members = ["op" - j_string("drop_schema_def"),
                   "schema" - j_string(Schema)]
    then
        schema_def_dropped(Schema, Bytes, Out)
    else if Members = ["op" - j_string("unknown_capability")] then
        % [RBND.1.3]: the first entry of the StreamHeader's (258)
        % packed `capabilities` (field 16) becomes 127, which `Capability`
        % does not allocate. `stream_edit.py`'s `unknown_capability`.
        list.find_first_match(
            ( pred({HeaderNum, _, _}::in) is semidet :- HeaderNum = 258 ),
            stream_atoms(Bytes, 0), {_, HStart, HEnd}),
        body_fields(Bytes, HStart, HEnd, HFields),
        list.find_first_match(
            ( pred({HField, _, _, _}::in) is semidet :- HField = 16 ),
            tamper_spans(HFields, HEnd), {_, _, CapEnd, Caps}),
        Caps = [First | _],
        First /\ 0x80u8 = 0u8,
        list.split_list(CapEnd - list.length(Caps), Bytes, CapBefore,
            [_ | CapAfter]),
        Out = CapBefore ++ [0x7Fu8] ++ CapAfter
    else if
        Members = ["firings" - j_array([j_int(I64), j_int(J64)]),
                   "op" - j_string("merge_timetags")]
    then
        % [LFST.9.3.6]: the j-th RuleFireAnnotation's (261) `timetag`
        % becomes the i-th's wherever one of `timetag_field`'s atoms carries
        % it, so two firings the engine keeps apart share one. No site when
        % i >= j, either has no annotation, the two already share a timetag,
        % or their varints differ in width. `stream_edit.py`'s
        % `merge_timetags`.
        I64 >= 0i64,
        I64 < J64,
        Atoms = stream_atoms(Bytes, 0),
        Notes = list.filter(
            ( pred({NNum, _, _}::in) is semidet :- NNum = 261 ), Atoms),
        list.index0(Notes, int64.cast_to_int(I64), {_, IStart, IEnd}),
        list.index0(Notes, int64.cast_to_int(J64), {_, JStart, JEnd}),
        varint_field_offset(Bytes, IStart, IEnd, 6, IAt),
        varint_field_offset(Bytes, JStart, JEnd, 6, JAt),
        byte_varint(Bytes, IAt, 0, 0, IValue, IValueEnd),
        byte_varint(Bytes, JAt, 0, 0, JValue, JValueEnd),
        IValue \= JValue,
        Width = IValueEnd - IAt,
        JValueEnd - JAt = Width,
        list.drop(IAt, Bytes, FromI),
        list.take(Width, FromI, IBytes),
        Sites = list.filter_map(
            ( func({SNum, SStart, SEnd}) = SAt is semidet :-
                timetag_field(SNum, SField),
                varint_field_offset(Bytes, SStart, SEnd, SField, SAt),
                byte_varint(Bytes, SAt, 0, 0, SValue, _),
                SValue = JValue
            ), Atoms),
        list.foldl(overwrite_at(IBytes), Sites, Bytes, Out)
    else if
        Members = ["cause" - j_int(Cause64), "index" - j_int(Index64),
                   "op" - j_string("withdraw_cause")]
    then
        % [RFCS.7a.2], [RFCS.7a.3]: the `index`-th FactWithdraw's
        % (327) `cause` (field 2), one varint byte, becomes `cause`, from 1 to
        % 127, so the recorded withdrawal differs from the one the replay
        % re-derives. No site when there is no `index`-th FactWithdraw, its
        % cause is not written or is wider than one byte, or it already is
        % `cause`. `stream_edit.py`'s `withdraw_cause`.
        Index64 >= 0i64,
        Cause64 >= 1i64,
        Cause64 =< 127i64,
        Index = int64.cast_to_int(Index64),
        Cause = int64.cast_to_int(Cause64),
        Withdraws = list.filter(
            ( pred({WNum, _, _}::in) is semidet :- WNum = 327 ),
            stream_atoms(Bytes, 0)),
        list.index0(Withdraws, Index, {_, WStart, WEnd}),
        varint_field_offset(Bytes, WStart, WEnd, 2, CauseAt),
        list.index0(Bytes, CauseAt, Old),
        Old /\ 0x80u8 = 0u8,
        uint8.cast_to_int(Old) \= Cause,
        list.split_list(CauseAt, Bytes, WBefore, [_ | WAfter]),
        Out = WBefore ++ [uint8.det_from_int(Cause)] ++ WAfter
    else if
        Members = ["field" - j_string(PField), "index" - j_int(PIndex64),
                   "op" - j_string("publish_name"), "to" - j_string(PTo)]
    then
        % [RFCS.27.2]: the `index`-th FactPublish's (331) `schema_name`
        % (field 1) or `rule_name` (field 2) becomes `to`'s UTF-8 octets, so
        % the recorded publish differs from the one the replay re-derives.
        % Every length is kept. No site when `field` names neither, there is
        % no `index`-th FactPublish, the field is not written, or `to` is of
        % another length in UTF-8 or the value it already holds.
        % `stream_edit.py`'s `publish_name`.
        publish_name_field(PField, PNum),
        PIndex64 >= 0i64,
        Publishes = list.filter(
            ( pred({PubNum, _, _}::in) is semidet :- PubNum = 331 ),
            stream_atoms(Bytes, 0)),
        list.index0(Publishes, int64.cast_to_int(PIndex64), {_, PStart, PEnd}),
        body_fields(Bytes, PStart, PEnd, PFields),
        list.find_first_match(
            ( pred({PF, _, _, _}::in) is semidet :- PF = PNum ),
            tamper_spans(PFields, PEnd), {_, _, PValueEnd, POld}),
        PNew = utf8_bytes(PTo),
        list.same_length(POld, PNew),
        POld \= PNew,
        overwrite_at(PNew, PValueEnd - list.length(POld), Bytes, Out)
    else if
        Members = ["atom" - j_int(A64), "op" - j_string("split_timetag")]
    then
        % [LFST.9.3.6]'s second direction: the `atom`-th CallIssued's
        % (262) `timetag` (field 8) becomes the least nonzero value of the
        % same varint width that none of `timetag_field`'s atoms carries, so
        % one firing's atoms carry two recorded timetags. No site when there
        % is no `atom`-th CallIssued, its timetag is not written, or no value
        % of its width is free. `stream_edit.py`'s `split_timetag`.
        A64 >= 0i64,
        Atoms = stream_atoms(Bytes, 0),
        Calls = list.filter(
            ( pred({CNum, _, _}::in) is semidet :- CNum = 262 ), Atoms),
        list.index0(Calls, int64.cast_to_int(A64), {_, CStart, CEnd}),
        varint_field_offset(Bytes, CStart, CEnd, 8, CAt),
        byte_varint(Bytes, CAt, 0, 0, _, CValueEnd),
        Width = CValueEnd - CAt,
        Width =< 8,
        Carried = list.filter_map(
            ( func({SNum, SStart, SEnd}) = SValue is semidet :-
                timetag_field(SNum, SField),
                varint_field_offset(Bytes, SStart, SEnd, SField, SAt),
                byte_varint(Bytes, SAt, 0, 0, SValue, _)
            ), Atoms),
        Low = ( if Width = 1 then 1 else 1 << (7 * (Width - 1)) ),
        least_free(Carried, Low, (1 << (7 * Width)) - 1, Free),
        overwrite_at(varint_u8(Free), CAt, Bytes, Out)
    else if
        Members = ["atom" - j_string(FName), "op" - j_string("fault_node")]
    then
        % [LFST.9.3.1]: the first such atom's `node_id`, one varint
        % byte, raised by one. No site when the recording holds none, or it is
        % not written, is wider than one byte or is 127. `stream_edit.py`'s
        % `fault_node`.
        fault_atom(FName, FNum, FField),
        first_frame(stream_atoms(Bytes, 0), FNum, 0, _, FStart, FEnd),
        varint_field_offset(Bytes, FStart, FEnd, FField, FAt),
        list.index0(Bytes, FAt, FOld),
        uint8.cast_to_int(FOld) < 127,
        overwrite_at([uint8.det_from_int(uint8.cast_to_int(FOld) + 1)], FAt,
            Bytes, Out)
    else if
        Members = ["atom" - j_string(DName), "op" - j_string("drop_fault")]
    then
        % [LFST.9.3.1]: the first such atom's frame removed. No site
        % when the recording holds none or does not walk to its end.
        % `stream_edit.py`'s `drop_fault`.
        fault_atom(DName, DNum, _),
        DAtoms = stream_atoms(Bytes, 0),
        list.last(DAtoms, {_, _, DLast}),
        DLast = list.length(Bytes),
        first_frame(DAtoms, DNum, 0, DFrom, _, DEnd),
        list.take(DFrom, Bytes, DBefore),
        list.drop(DEnd, Bytes, DAfter),
        Out = DBefore ++ DAfter
    else if Members = ["op" - j_string("append_engine_error")] then
        % [RFCS.6.7]: an EngineError (330) after the last atom: fault
        % 1, seq 999, rule_name `r`. No site when the recording does not walk to
        % its end or holds one. `stream_edit.py`'s `append_engine_error`.
        EAtoms = stream_atoms(Bytes, 0),
        list.last(EAtoms, {_, _, ELast}),
        ELast = list.length(Bytes),
        not first_frame(EAtoms, 330, 0, _, _, _),
        EInner = tamper_delimited(330, t_int(1, 1) ++ t_int(4, 999)
            ++ tamper_delimited(5, [0x72u8])),
        Out = Bytes ++ [0x0Au8] ++ varint_u8(list.length(EInner)) ++ EInner
    else if Members = ["op" - j_string("seed_after_event")] then
        % [RFCS.26.2]: the first CacheSeed's (6) frame moved, whole,
        % to just after the first atom after it that is no prelude atom
        % (`prelude_atom`), so a seed follows an event atom. No site when there
        % is no CacheSeed or no such atom, or the recording does not walk to
        % its end. `stream_edit.py`'s `seed_after_event`.
        Atoms = stream_atoms(Bytes, 0),
        list.last(Atoms, {_, _, LastEnd}),
        LastEnd = list.length(Bytes),
        seed_and_event(Atoms, 0, no, Seed, Event),
        list.index0(Atoms, Seed, {_, _, SeedEnd}),
        list.index0(Atoms, Event, {_, _, EventEnd}),
        ( if Seed = 0 then
            SeedAt = 0
        else
            list.index0(Atoms, Seed - 1, {_, _, SeedAt})
        ),
        list.split_list(SeedAt, Bytes, Before, FromSeed),
        list.split_list(SeedEnd - SeedAt, FromSeed, SeedFrame, AfterSeed),
        list.split_list(EventEnd - SeedEnd, AfterSeed, Between, After),
        Out = Before ++ Between ++ SeedFrame ++ After
    else
        Members = ["op" - j_string("retract_unknown_fact_id")],
        Atoms = stream_atoms(Bytes, 0),
        not list.find_first_match(
            ( pred({Num5, _, _}::in) is semidet :- Num5 = 5 ), Atoms, _),
        Carried = list.filter_map(
            ( func({Num, Start, End}) = Id is semidet :-
                ( Num = 1 ; Num = 326 ),
                varint_field_offset(Bytes, Start, End, 1, At),
                byte_varint(Bytes, At, 0, 0, Id, _)
            ), Atoms),
        not list.member(0x7F, Carried),
        list.find_first_match(
            ( pred({Num, _, _}::in) is semidet :- Num = 2 ), Atoms,
            {_, RStart, REnd}),
        varint_field_offset(Bytes, RStart, REnd, 1, IdAt),
        list.index0(Bytes, IdAt, IdByte),
        IdByte /\ 0x80u8 = 0u8,
        list.split_list(IdAt, Bytes, Before, [_ | After]),
        Out = Before ++ [0x7Fu8] ++ After
    ).

    % `stream_edit.py`'s `drop_schema_def`: every SchemaDef (256) and Slot
    % (257) atom of `Schema` is removed, and its FactAsserts (1) are kept
    % ([RFCS.5.3], [RFCS.5.4]). Fails when the frames do not walk to the end,
    % `Schema` is empty, or there is no SchemaDef for it or no FactAssert
    % naming it.
    %
:- pred schema_def_dropped(string::in, list(uint8)::in, list(uint8)::out)
    is semidet.

schema_def_dropped(Schema, Bytes, Out) :-
    Name = utf8_bytes(Schema),
    Name = [_ | _],
    dsc_frames(Bytes, 0, Frames),
    list.find_first_match(frame_names(Bytes, 256, 1, Name), Frames, _),
    list.find_first_match(frame_names(Bytes, 1, 2, Name), Frames, _),
    Kept = list.filter(
        (pred(F::in) is semidet :-
            not frame_names(Bytes, 256, 1, Name, F),
            not frame_names(Bytes, 257, 1, Name, F)),
        Frames),
    Out = list.condense(list.map(
        (func({_, Start, _, End}) = byte_slice(Bytes, Start, End)), Kept)).

    % Whether a frame is atom `Num` whose string field `Field` is `Name`.
    %
:- pred frame_names(list(uint8)::in, int::in, int::in, list(uint8)::in,
    {int, int, int, int}::in) is semidet.

frame_names(Bytes, Num, Field, Name, {Num, _, Body, End}) :-
    body_fields(Bytes, Body, End, Fields),
    first_value(Fields, Field, Name).

:- func byte_slice(list(uint8), int, int) = list(uint8).

byte_slice(Bytes, Start, End) = Slice :-
    list.split_upto(Start, Bytes, _, From),
    list.split_upto(End - Start, From, Slice, _).

    % `test_runner_codes.py`'s `test_drop_schema_def_*` cases.
    % @spec [RCTS.1.2.18]
    %
:- pred stream_edit_checks(tally::in, tally::out, io::di, io::uo) is det.

stream_edit_checks(!T, !IO) :-
    Atom = (func(N, Body) = [0x0Au8] ++ varint_u8(list.length(Inner))
            ++ Inner :-
        Inner = varint_u8(N * 8 + 2) ++ varint_u8(list.length(Body)) ++ Body),
    Named = (func(NS) = [0x0Au8] ++ varint_u8(list.length(utf8_bytes(NS)))
        ++ utf8_bytes(NS)),
    Head = Atom(258, [0x08u8, 0x01u8]),
    TrigDef = Atom(256, Named("Trig")),
    TrigSlot = Atom(257, Named("Trig") ++ [0x12u8, 0x01u8, 0x76u8]),
    TickDef = Atom(256, Named("Tick")),
    TickSlot = Atom(257, Named("Tick") ++ [0x12u8, 0x01u8, 0x76u8]),
    Assert = Atom(1, [0x08u8, 0x01u8, 0x12u8, 0x04u8] ++ utf8_bytes("Trig")),
    Pump = Atom(4, [0x08u8, 0x01u8]),
    Drop = (func(DS) = j_object(object(["op" - j_string("drop_schema_def"),
        "schema" - j_string(DS)]))),
    % Fails on: a Slot of the schema left behind, another schema's atoms
    % removed, the FactAssert dropped, or a byte of the rest moved.
    check("RCTS.1.2.18:drop_schema_def removes the announcement whole",
        ( if
            stream_mutated(Drop("Trig"),
                Head ++ TrigDef ++ TrigSlot ++ TickDef ++ TickSlot ++ Assert,
                Out),
            Out = Head ++ TickDef ++ TickSlot ++ Assert
          then yes else no ), !T, !IO),
    Announced = TrigDef ++ Assert,
    check("RCTS.1.2.18:drop_schema_def needs an announcement and an assert",
        ( if
            not stream_mutated(Drop("Trig"), Assert, _),
            not stream_mutated(Drop("Tick"), Announced, _),
            not stream_mutated(Drop("Trig"), TrigDef ++ Pump, _),
            not stream_mutated(Drop(""), Announced, _),
            not stream_mutated(Drop("Trig"), Announced ++ [0x0Au8], _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:drop_schema_def takes exactly a schema name",
        ( if
            not stream_mutated(j_object(object(
                ["op" - j_string("drop_schema_def")])), Announced, _),
            not stream_mutated(j_object(object(
                ["op" - j_string("drop_schema_def"),
                 "schema" - j_int(1i64)])), Announced, _),
            not stream_mutated(j_object(object(
                ["op" - j_string("drop_schema_def"),
                 "schema" - j_string("Trig"), "slot" - j_string("v")])),
                Announced, _)
          then yes else no ), !T, !IO).

:- func record_event({seq, stream_event}) = record_item.

record_event({S, Ev}) = ri_event(S, Ev).

:- func utf8_bytes(string) = list(uint8).

utf8_bytes(S) = list.map(uint8.det_from_int, Units) :-
    string.to_utf8_code_unit_list(S, Units).

    % Each atom that carries a `timetag`, and the field it is in
    % ([RCTS.1.2.24], [RCTS.1.2.18]): RuleFireAnnotation, CallIssued,
    % ComputationError and BoundsError. `stream_edit.py`'s `TIMETAG_FIELDS`.
    %
:- pred timetag_field(int::in, int::out) is semidet.

timetag_field(261, 6).
timetag_field(262, 8).
timetag_field(325, 3).
timetag_field(329, 5).

    % `split_timetag`'s value: the least from `V` to `High` not in `Carried`.
    %
:- pred least_free(list(int)::in, int::in, int::in, int::out) is semidet.

least_free(Carried, V, High, Free) :-
    V =< High,
    ( if list.member(V, Carried) then
        least_free(Carried, V + 1, High, Free)
    else
        Free = V
    ).

    % `seed_after_event`'s sites: the index of the first CacheSeed (6), and of
    % the first atom after it that is no prelude atom.
    %
:- pred seed_and_event(list({int, int, int})::in, int::in, maybe(int)::in,
    int::out, int::out) is semidet.

seed_and_event([{Num, _, _} | Atoms], I, MaybeSeed, Seed, Event) :-
    ( if MaybeSeed = yes(S), not prelude_atom(Num) then
        Seed = S,
        Event = I
    else if MaybeSeed = no, Num = 6 then
        seed_and_event(Atoms, I + 1, yes(I), Seed, Event)
    else
        seed_and_event(Atoms, I + 1, MaybeSeed, Seed, Event)
    ).

    % The prelude's atoms, which are no stream event ([RFCS.5.1],
    % [RFCS.26.1]): StreamHeader, SchemaDef, Slot and CacheSeed.
    %
:- pred prelude_atom(int::in) is semidet.

prelude_atom(258).
prelude_atom(256).
prelude_atom(257).
prelude_atom(6).

    % `Bytes` with `New` written over its bytes from `At`, one for one.
    %
:- pred overwrite_at(list(uint8)::in, int::in, list(uint8)::in,
    list(uint8)::out) is semidet.

overwrite_at(New, At, Bytes, Out) :-
    list.split_list(At, Bytes, Before, Rest),
    list.drop(list.length(New), Rest, After),
    Out = Before ++ New ++ After.

    % `stream_edit.py`'s `offset_timetags` ([RCTS.1.2.24]): every nonzero
    % `timetag` plus `N`, each atom it changes re-framed, since a varint may
    % widen. Fails when the recording carries no nonzero `timetag`, or does
    % not walk to its end.
    %
:- pred timetags_offset(int::in, list(uint8)::in, list(uint8)::out)
    is semidet.

timetags_offset(N, Bytes, Out) :-
    list.foldl3(offset_frame(N, Bytes), stream_atoms(Bytes, 0), 0, End,
        [], RevFrames, no, Changed),
    Changed = yes,
    End = list.length(Bytes),
    Out = list.condense(list.reverse(RevFrames)).

    % One frame, from where the last ended to its body's end: re-framed with
    % its `timetag` offset when it carries a nonzero one, else as it was.
    %
:- pred offset_frame(int::in, list(uint8)::in, {int, int, int}::in,
    int::in, int::out, list(list(uint8))::in, list(list(uint8))::out,
    bool::in, bool::out) is semidet.

offset_frame(N, Bytes, {Num, BodyStart, BodyEnd}, FrameStart, BodyEnd,
        !RevFrames, !Changed) :-
    list.drop(FrameStart, Bytes, FromFrame),
    list.take(BodyEnd - FrameStart, FromFrame, Frame),
    list.drop(BodyStart - FrameStart, Frame, Body),
    ( if timetag_field(Num, Field) then
        offset_body(Field, N, Body, NewBody, no, Hit),
        ( if Hit = yes then
            Inner = tamper_delimited(Num, NewBody),
            !:RevFrames = [[0x0Au8] ++ varint_u8(list.length(Inner)) ++ Inner
                | !.RevFrames],
            !:Changed = yes
        else
            !:RevFrames = [Frame | !.RevFrames]
        )
    else
        !:RevFrames = [Frame | !.RevFrames]
    ).

    % A body with varint field `Field`'s value plus `N` where it is nonzero;
    % `Hit` says whether it was. Fails when the body does not walk.
    %
:- pred offset_body(int::in, int::in, list(uint8)::in, list(uint8)::out,
    bool::in, bool::out) is semidet.

offset_body(Field, N, Body, Out, !Hit) :-
    ( if Body = [] then
        Out = []
    else
        byte_varint(Body, 0, 0, 0, Key, ValueAt),
        Wire = Key /\ 7,
        ( if Wire = 0 then
            byte_varint(Body, ValueAt, 0, 0, Value, Next),
            ( if Key >> 3 = Field, Value \= 0 then
                Head = varint_u8(Key) ++ varint_u8(Value + N),
                !:Hit = yes
            else
                list.take(Next, Body, Head)
            )
        else if Wire = 2 then
            byte_varint(Body, ValueAt, 0, 0, Len, LenEnd),
            Next = LenEnd + Len,
            list.take(Next, Body, Head)
        else if Wire = 1 then
            Next = ValueAt + 8,
            list.take(Next, Body, Head)
        else
            Wire = 5,
            Next = ValueAt + 4,
            list.take(Next, Body, Head)
        ),
        list.drop(Next, Body, Rest),
        offset_body(Field, N, Rest, Out0, !Hit),
        Out = Head ++ Out0
    ).

    % `Bytes` with every occurrence of `From` replaced by `To`; `Found0`
    % threads whether any occurrence was met.
    %
:- pred replace_all(list(uint8)::in, list(uint8)::in, list(uint8)::in,
    list(uint8)::out, bool::in, bool::out) is det.

replace_all(_, _, [], [], !Found).
replace_all(From, To, [B | Bs], Out, !Found) :-
    ( if list.append(From, Rest, [B | Bs]) then
        !:Found = yes,
        replace_all(From, To, Rest, Out0, !Found),
        Out = To ++ Out0
    else
        replace_all(From, To, Bs, Out0, !Found),
        Out = [B | Out0]
    ).

    % Where varint field `Field`'s value starts in the body `Start`..`End`:
    % `stream_edit.py`'s `varint_field_offset`.
    %
:- pred varint_field_offset(list(uint8)::in, int::in, int::in, int::in,
    int::out) is semidet.

varint_field_offset(Bytes, Pos, End, Field, At) :-
    Pos < End,
    byte_varint(Bytes, Pos, 0, 0, Key, ValueAt),
    Num = Key >> 3,
    Wire = Key /\ 7,
    ( if Num = Field, Wire = 0 then
        At = ValueAt
    else
        ( if Wire = 0 then
            byte_varint(Bytes, ValueAt, 0, 0, _, Next)
        else if Wire = 2 then
            byte_varint(Bytes, ValueAt, 0, 0, Len, LenEnd),
            Next = LenEnd + Len
        else if Wire = 1 then
            Next = ValueAt + 8
        else
            Wire = 5,
            Next = ValueAt + 4
        ),
        varint_field_offset(Bytes, Next, End, Field, At)
    ).

    % `field_order` [RCTS.1.2.19] over this runtime's writer: the run is
    % encoded to RFCS and judged by `fo_judge` against the field table
    % `field_order.py --table` derives from `proto/`, attached as `table`.
    % The walk is `field_order_walk`'s, not `field_order.py`'s, so the two
    % runtimes are not judged by one reading of the bytes.
    %
:- func field_order_result(string, json_members, program, engine,
    list(stamped)) = behave_result.

field_order_result(Kind, Expect, P, EA, Stamped) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    Records = list.map((func({S, _, Ev}) = {S, Ev}), list.reverse(RevAll)),
    Meta = session_header(EA),
    Ctx = rfcs_ctx(schemas(P), engine_interns(EA)),
    encode_recording(Meta, Ctx, from_ns(0u64), prelude_seeds(EA),
        list.map(record_event, Records), Bytes, Unencodable),
    ( if Unencodable = [_ | _] then
        Result = behave_result(bo_unsupported, Kind,
            "the run emitted events the recorder cannot encode: "
                ++ string.string(Unencodable))
    else if
        lookup_member(Expect, "table", TJ),
        fo_table(TJ, Root, Table)
    then
        ( if fo_wanted_atoms(Expect, Want) then
            Verdict = fo_judge(Root, Table, Want, "recording", Bytes),
            (
                Verdict = fo_ok,
                Result = behave_result(bo_pass, Kind, "")
            ;
                Verdict = fo_refused(Why),
                Result = behave_result(bo_fail, Kind, Why)
            )
        else
            Result = behave_result(bo_fail, Kind, "no `atoms` list of names")
        )
    else
        Result = behave_result(bo_fail, Kind,
            "no field table: `field_order.py --table` writes it, and the "
                ++ "gate stages it as behaviour/FIELD_ORDER_TABLE.json")
    ).

    % `rfcs_roundtrip` over this runtime's writer and reader: encode the run
    % to RFCS, splice an unknown skip-band atom in after the `StreamHeader`
    % (at field 2000, or the fixture's `splice_field`, [RCTS.1.2.20]),
    % decode, and require:
    %
    %   * the stream decodes past the spliced atom [RFCS.16.3];
    %   * `StreamHeader` is the first atom [RFCS.4.1];
    %   * a `SchemaDef` precedes the first `FactAssert` [RFCS.6.5];
    %   * the header's `ds_version` and `session_id` round-trip
    %     [LDET.1.10];
    %   * the known atoms, in order, equal `expected_atoms`;
    %   * `expected_first_seq` ([RCTS.1.2.10]): the `seq` of the first event
    %     atom, `dsm_first_seq`, not `dsm_events`, which leaves out the
    %     compare atoms. Only the first is pinned: a recording's later seqs
    %     skip the events the recorder does not write;
    %   * `expected_call_correlations` ([RFCS.15.2]): each `CallIssued`'s
    %     `correlation`, read off the frames, since `decode_stream` keeps no
    %     `CallIssued` as an event. An absent field reads as `""`;
    %   * `expected_withdraw_causes` ([RFCS.7a.2]): each `FactWithdraw`'s
    %     cause;
    %   * `expected_slots` ([RFCS.5.1]): each `Slot` of the schemas it names
    %     carries exactly the fields it lists;
    %   * `expected_event_ids` ([RCTS.1.2.23], [RFCS.6.8]): each
    %     `FactAssert`'s `event_id`;
    %   * `expected_fact_ids` ([RCTS.1.2.23], [RFCS.6.9]): each `FactAssert`,
    %     `FactEmit` and `FactWithdraw` as its name and `fact_id`. A refused
    %     assert step ([RCTS.1.2.27]) is in the list;
    %   * `expected_emits` ([RCTS.1.2.23], [RFCS.6a.2]): each `FactEmit` as
    %     its `rule_name`;
    %   * `expected_publishes` ([RCTS.1.2.23], [RFCS.27.1]): each
    %     `FactPublish` as its `schema_name` and `rule_name`;
    %   * `expected_stream_kinds` ([RCTS.1.2.23]): the run's events cut down
    %     to the kinds it names ([RCTS.1.2.10]).
    %
    % Lists are in stream order. Every field of [RCTS.1.2.23] is type-checked
    % first (`rcts_1_2_23_refusal`).
    %
:- func rfcs_roundtrip_result(string, json_members, program, engine,
    list(stamped), list(string)) = behave_result.

rfcs_roundtrip_result(Kind, Expect, P, E, Stamped, Kinds) = Result :-
    ( if rcts_1_2_23_refusal(Expect) = yes(Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else
        Result = rfcs_roundtrip_checked(Kind, Expect, P, E, Stamped, Kinds)
    ).

:- func rfcs_roundtrip_checked(string, json_members, program, engine,
    list(stamped), list(string)) = behave_result.

rfcs_roundtrip_checked(Kind, Expect, P, E, Stamped, Kinds) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    All = list.map((func({S, _, Ev}) = {S, Ev}), list.reverse(RevAll)),
    % The host's seeds go in the prelude ([RFCS.26.1]). `late_start` N
    % ([RCTS.1.2.23]) records from the N-th step on, with no seeds: a
    % recorder attached after the first stream event writes no `CacheSeed`.
    % `encode_recording` writes the seeds it is passed, so here the harness
    % leaves them out.
    ( if int_member(Expect, "late_start", N) then
        ( if late_records(Kind, P, Expect, N, Stamped, Late) then
            Records0 = Late,
            LateWhy = ""
        else
            Records0 = All,
            LateWhy = "the " ++ string.int_to_string(N) ++ " step(s) before "
                ++ "`late_start` put no event on the stream, so the recording "
                ++ "would begin at its first event ([RCTS.1.2.23])"
        ),
        Seeds = []
    else
        Records0 = All,
        LateWhy = "",
        Seeds = prelude_seeds(E)
    ),
    Rewrite = rewrite_withdraw_cause(Expect, Records0),
    (
        Rewrite = rewrite_missing(Why0),
        Records = Records0
    ;
        Rewrite = rewrite_none,
        Why0 = "",
        Records = Records0
    ;
        Rewrite = rewrite_done(Records),
        Why0 = ""
    ),
    Why = ( if LateWhy \= "" then LateWhy else Why0 ),
    Meta = session_header(E),
    encode_recording(Meta, rfcs_ctx(schemas(P), engine_interns(E)),
        from_ns(0u64), Seeds, list.map(record_event, Records),
        Bytes, Unencodable),
    ( if Why \= "" then
        Result = behave_result(bo_fail, Kind, Why)
    else if Unencodable = [_ | _] then
        Result = behave_result(bo_unsupported, Kind,
            "the run emitted events the recorder cannot encode")
    else if rcts_1_2_20_splice_field(Expect) = sf_refused(SpliceWhy) then
        Result = behave_result(bo_fail, Kind, SpliceWhy)
    else if
        frame_starts(init_reader(from_bytes(Bytes)), [], Starts),
        Starts = [_, Second | _],
        rcts_1_2_20_splice_field(Expect) = sf_field(SpliceField)
    then
        list.det_split_list(Second, Bytes, FirstAtom, RestAtoms),
        put_delimited(SpliceField,
            list.map((func(C) = uint8.det_from_int(char.to_int(C))),
                string.to_char_list("future-atom-body")),
            init_builder, Inner),
        put_delimited(1u32, builder_bytes(Inner), init_builder, Outer),
        Spliced = FirstAtom ++ builder_bytes(Outer) ++ RestAtoms,
        Atoms = known_atom_names(init_reader(from_bytes(Spliced)), []),
        decode_stream(from_bytes(Spliced), init_interns, Decoded),
        Want = string_array(array_member(Expect, "expected_atoms")),
        ( if Decoded = decode_failed(Clause, Offset) then
            Result = behave_result(bo_fail, Kind,
                string.format(
                    "the spliced stream does not decode: %s at %d",
                    [s(Clause), i(Offset)]))
        else if Decoded = unannounced_schema(_, USeq, UOffset) then
            % Its own arm, or the `decoded(DS)` checks below would fail to
            % match it and let the stream through.
            Result = behave_result(bo_fail, Kind,
                string.format("the spliced stream's FactAssert at seq %s "
                    ++ "(byte %d) names a schema no SchemaDef announced "
                    ++ "([RFCS.5.4])",
                    [s(string.string(USeq)), i(UOffset)]))
        else if not Atoms = ["StreamHeader" | _] then
            Result = behave_result(bo_fail, Kind,
                "StreamHeader is not the first atom: " ++ string.string(Atoms))
        else if not schema_def_before_fact_assert(Atoms, no) then
            Result = behave_result(bo_fail, Kind,
                "a FactAssert precedes every SchemaDef: "
                    ++ string.string(Atoms))
        else if
            Decoded = decoded(DS),
            ( DS ^ dsm_meta ^ sm_ds_version \= Meta ^ sm_ds_version
            ; DS ^ dsm_meta ^ sm_session \= Meta ^ sm_session )
        then
            Result = behave_result(bo_fail, Kind,
                "the header does not round-trip")
        else if
            lookup_member(Expect, "expected_atoms", _),
            Atoms \= Want
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs atom sequence: want " ++ string.string(Want)
                    ++ ", got " ++ string.string(Atoms))
        else if
            lookup_member(Expect, "expected_first_seq", WantFirstJ),
            Decoded = decoded(DFirst),
            not (
                WantFirstJ = j_int(WantFirst),
                DFirst ^ dsm_first_seq = yes(GotFirst),
                int64.cast_from_uint64(GotFirst) = WantFirst
            )
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs first event seq: want " ++ string.string(WantFirstJ)
                    ++ ", got " ++ string.string(DFirst ^ dsm_first_seq))
        else if
            lookup_member(Expect, "expected_call_correlations", _),
            WantCorrs = string_array(
                array_member(Expect, "expected_call_correlations")),
            GotCorrs = call_correlations(init_reader(from_bytes(Spliced)), []),
            GotCorrs \= WantCorrs
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs recorded call correlations: want "
                    ++ string.string(WantCorrs) ++ ", got "
                    ++ string.string(GotCorrs))
        else if
            lookup_member(Expect, "expected_withdraw_causes", _),
            Decoded = decoded(DCauses),
            WantCauses = string_array(
                array_member(Expect, "expected_withdraw_causes")),
            GotCauses = withdraw_cause_names(DCauses ^ dsm_events),
            GotCauses \= WantCauses
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs withdrawal causes: want " ++ string.string(WantCauses)
                    ++ ", got " ++ string.string(GotCauses))
        else if
            lookup_member(Expect, "expected_slots", _),
            WantSlots = array_member(Expect, "expected_slots"),
            Named = list.filter_map(slot_schema_name, WantSlots),
            not (
                announced_slots(init_reader(from_bytes(Bytes)), Named, [],
                    GotSlots),
                GotSlots = WantSlots
            )
        then
            ( if
                announced_slots(init_reader(from_bytes(Bytes)), Named, [],
                    Got)
            then
                Result = behave_result(bo_fail, Kind,
                    "rfcs Slot announcements: want " ++ string.string(WantSlots)
                        ++ ", got " ++ string.string(Got))
            else
                Result = behave_result(bo_fail, Kind,
                    "rfcs Slot atom does not parse")
            )
        else if
            lookup_member(Expect, "expected_event_ids", _),
            WantIds = string_array(array_member(Expect, "expected_event_ids")),
            GotIds = fact_assert_event_ids(init_reader(from_bytes(Bytes)), []),
            GotIds \= WantIds
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs FactAssert event_ids: want " ++ string.string(WantIds)
                    ++ ", got " ++ string.string(GotIds))
        else if
            lookup_member(Expect, "expected_fact_ids", _),
            WantFids = list.filter_map(fact_id_entry,
                array_member(Expect, "expected_fact_ids")),
            GotFids = recorded_fact_ids(init_reader(from_bytes(Bytes)), []),
            GotFids \= WantFids
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs fact_ids: want " ++ string.string(WantFids)
                    ++ ", got " ++ string.string(GotFids))
        else if
            lookup_member(Expect, "expected_emits", _),
            WantEmits = list.filter_map(emit_entry,
                array_member(Expect, "expected_emits")),
            GotEmits = recorded_emits(init_reader(from_bytes(Bytes)), []),
            GotEmits \= WantEmits
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs FactEmits: want " ++ string.string(WantEmits)
                    ++ ", got " ++ string.string(GotEmits))
        else if
            lookup_member(Expect, "expected_publishes", _),
            WantPubs = list.filter_map(publish_entry,
                array_member(Expect, "expected_publishes")),
            GotPubs = recorded_publishes(init_reader(from_bytes(Bytes)), []),
            GotPubs \= WantPubs
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs FactPublishes: want " ++ string.string(WantPubs)
                    ++ ", got " ++ string.string(GotPubs))
        else if
            lookup_member(Expect, "expected_cache_seeds", _),
            WantSeeds = list.filter_map(cache_seed_entry,
                array_member(Expect, "expected_cache_seeds")),
            GotSeeds = recorded_cache_seeds(init_reader(from_bytes(Bytes)), []),
            GotSeeds \= WantSeeds
        then
            Result = behave_result(bo_fail, Kind,
                "rfcs CacheSeeds: want " ++ string.string(WantSeeds)
                    ++ ", got " ++ string.string(GotSeeds))
        else if
            lookup_member(Expect, "expected_stream_kinds", _),
            WantKinds = string_array(
                array_member(Expect, "expected_stream_kinds")),
            Projected = projection(WantKinds, Kinds),
            Projected \= WantKinds
        then
            Result = behave_result(bo_fail, Kind,
                "the stream's events of the stated kinds are ["
                    ++ string.join_list(", ", Projected)
                    ++ "], want [" ++ string.join_list(", ", WantKinds)
                    ++ "]; whole stream ["
                    ++ string.join_list(", ", Kinds) ++ "]")
        else
            Result = behave_result(bo_pass, Kind, "")
        )
    else
        Result = behave_result(bo_fail, Kind,
            "the recording has fewer than two atoms to splice between")
    ).

    % [RCTS.1.2.20]: the field number `rfcs_roundtrip` splices its unknown atom
    % at. Absent, 2000. Given, an integer in the skip band ([RFCS.16.2]) that
    % `atom_of_field` does not know, since a known one is decoded rather than
    % skipped.
    %
:- type splice_field
    --->    sf_field(uint32)
    ;       sf_refused(string).

:- func rcts_1_2_20_splice_field(json_members) = splice_field.

rcts_1_2_20_splice_field(Expect) = Result :-
    ( if lookup_member(Expect, "splice_field", J) then
        ( if J = j_int(N) then
            ( if N < 256i64 ; N > 2047i64 then
                Result = sf_refused(string.format(
                    "expect.splice_field %d is outside the skip band, "
                        ++ "256-2047 ([RCTS.1.2.20], [RFCS.16.2])",
                    [i(int64.cast_to_int(N))]))
            else
                Field = uint32.det_from_int(int64.cast_to_int(N)),
                ( if atom_of_field(Field, _) then
                    Result = sf_refused(string.format(
                        "expect.splice_field %d is an atom the registry names, "
                            ++ "which a reader decodes rather than skips "
                            ++ "([RCTS.1.2.20])",
                        [i(int64.cast_to_int(N))]))
                else
                    Result = sf_field(Field)
                )
            )
        else
            Result = sf_refused("expect.splice_field is not an integer "
                ++ "([RCTS.1.2.20])")
        )
    else
        Result = sf_field(2000u32)
    ).

    % [RCTS.1.2.20]: a fixture of another kind carrying `expect.splice_field`
    % fails.
    %
:- func splice_field_placed(string, json_members, behave_result)
    = behave_result.

splice_field_placed(Kind, Expect, Result0) =
    ( if Kind \= "rfcs_roundtrip", lookup_member(Expect, "splice_field", _) then
        behave_result(bo_fail, Kind, "expect.splice_field is `rfcs_roundtrip`'s "
            ++ "alone ([RCTS.1.2.20]); this fixture's kind is `" ++ Kind ++ "`")
    else
        Result0
    ).

    % `test_runner_codes.py`'s `TestTimetagOffset` and `TestMergeTimetags`
    % cases.
    % @spec [RCTS.1.2.24] [RCTS.1.2.18]
    %
:- pred timetag_checks(tally::in, tally::out, io::di, io::uo) is det.

timetag_checks(!T, !IO) :-
    Atom = (func(ANum, ABody) = [0x0Au8] ++ varint_u8(list.length(AInner))
            ++ AInner :-
        AInner = tamper_delimited(ANum, ABody)),
    Note = (func(NTT) = Atom(261, tamper_delimited(2, utf8_bytes("r"))
        ++ t_int(6, NTT))),
    Assert = Atom(1, t_int(1, 1)),
    Fault = Atom(325, t_int(3, 0)),
    Call = (func(CTT) = Atom(262, t_int(8, CTT))),
    Bounds = (func(BTT) = Atom(329, t_int(5, BTT))),
    % Fails on: an atom kind left out, a zero timetag offset, another field
    % touched, or a frame left at its old length when 100 + 200 widens.
    check("RCTS.1.2.24:timetag_offset offsets every nonzero timetag and "
            ++ "re-frames the atom",
        ( if
            timetags_offset(200,
                Assert ++ Note(100) ++ Call(100) ++ Fault ++ Bounds(100), Out),
            Out = Assert ++ Note(300) ++ Call(300) ++ Fault ++ Bounds(300)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.24:timetag_offset with no nonzero timetag has no site",
        ( if
            not timetags_offset(5, Assert, _),
            not timetags_offset(5, Assert ++ Fault, _)
          then yes else no ), !T, !IO),
    Offset = (func(OJ) = rcts_1_2_24_offset(object(["timetag_offset" - OJ]))),
    % Fails on: an offset that is not a positive integer taken as one.
    check("RCTS.1.2.24:timetag_offset is a positive integer or the fixture "
            ++ "fails",
        ( if
            Offset(j_int(1i64)) = offset(1),
            rcts_1_2_24_offset(object([])) = no_offset,
            Offset(j_int(0i64)) = offset_refused(_),
            Offset(j_int(-1i64)) = offset_refused(_),
            Offset(j_bool(yes)) = offset_refused(_),
            Offset(j_float(1.0)) = offset_refused(_),
            Offset(j_string("1")) = offset_refused(_),
            Offset(j_null) = offset_refused(_)
          then yes else no ), !T, !IO),
    Passed = (func(PK) = behave_result(bo_pass, PK, "")),
    Placed = (func(PK2) = timetag_offset_placed(PK2,
        object(["timetag_offset" - j_int(1i64)]), Passed(PK2)) ^ br_outcome),
    % Fails on: a kind that would carry the field and never read it.
    check("RCTS.1.2.24:timetag_offset is replay_determinism's alone",
        ( if
            Placed("replay_determinism") = bo_pass,
            Placed("replay_refused") = bo_fail,
            Placed("rfcs_roundtrip") = bo_fail,
            Placed("event_sequence") = bo_fail
          then yes else no ), !T, !IO),
    Merge = (func(MI, MJ) = j_object(object([
        "op" - j_string("merge_timetags"),
        "firings" - j_array([j_int(MI), j_int(MJ)])]))),
    % Fails on: an atom carrying the j-th value left alone, the i-th's own
    % atom edited, or a length moved.
    check("RCTS.1.2.18:merge_timetags gives the j-th timetag the i-th's "
            ++ "wherever it is carried",
        ( if
            stream_mutated(Merge(0i64, 1i64),
                Note(5) ++ Note(7) ++ Call(7) ++ Bounds(7) ++ Call(9),
                Note(5) ++ Note(5) ++ Call(5) ++ Bounds(5) ++ Call(9))
          then yes else no ), !T, !IO),
    Two = Note(5) ++ Note(7),
    % Fails on: an index with no annotation, two already sharing a timetag,
    % two whose varints differ in width, and firings of the wrong shape.
    check("RCTS.1.2.18:merge_timetags without a site",
        ( if
            not stream_mutated(Merge(1i64, 0i64), Two, _),
            not stream_mutated(Merge(0i64, 0i64), Two, _),
            not stream_mutated(Merge(0i64, 2i64), Two, _),
            not stream_mutated(Merge(-1i64, 1i64), Two, _),
            not stream_mutated(Merge(0i64, 1i64), Note(5) ++ Note(5), _),
            not stream_mutated(Merge(0i64, 1i64), Note(5) ++ Note(200), _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags"),
                "firings" - j_array([j_int(0i64), j_bool(yes)])])), Two, _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags"),
                "firings" - j_array([j_int(0i64)])])), Two, _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags"),
                "firings" - j_array([j_int(0i64), j_int(1i64),
                    j_int(1i64)])])), Two, _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags"),
                "firings" - j_string("0,1")])), Two, _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags"),
                "firings" - j_array([j_int(0i64), j_int(1i64)]),
                "extra" - j_int(1i64)])), Two, _),
            not stream_mutated(j_object(object([
                "op" - j_string("merge_timetags")])), Two, _)
          then yes else no ), !T, !IO).

    % [RCTS.1.2.24]: `expect.timetag_offset` is absent, a positive integer, or
    % anything else, which fails the fixture. A JSON `true` is no integer.
    %
:- type offset_field
    --->    no_offset
    ;       offset(int)
    ;       offset_refused(string).

:- func rcts_1_2_24_offset(json_members) = offset_field.

rcts_1_2_24_offset(Expect) = Field :-
    ( if lookup_member(Expect, "timetag_offset", J) then
        ( if J = j_int(N), N >= 1i64 then
            Field = offset(int64.cast_to_int(N))
        else
            Field = offset_refused("expect.timetag_offset is not a positive "
                ++ "integer ([RCTS.1.2.24])")
        )
    else
        Field = no_offset
    ).

    % [RCTS.1.2.24]: `expect.timetag_offset` is `replay_determinism`'s alone.
    %
:- func timetag_offset_placed(string, json_members, behave_result)
    = behave_result.

timetag_offset_placed(Kind, Expect, Result0) =
    ( if
        Kind \= "replay_determinism",
        lookup_member(Expect, "timetag_offset", _)
    then
        behave_result(bo_fail, Kind, "expect.timetag_offset is "
            ++ "`replay_determinism`'s alone ([RCTS.1.2.24]); this fixture's "
            ++ "kind is `" ++ Kind ++ "`")
    else
        Result0
    ).

    % `test_conformance.py`'s `test_rcts_1_2_20__*` cases.
    % @spec [RCTS.1.2.20]
    %
:- pred splice_field_checks(tally::in, tally::out, io::di, io::uo) is det.

splice_field_checks(!T, !IO) :-
    Field = (func(Pairs) = rcts_1_2_20_splice_field(object(Pairs))),
    check("RCTS.1.2.20:absent, the field is 2000",
        ( if Field([]) = sf_field(2000u32) then yes else no ), !T, !IO),
    check("RCTS.1.2.20:260, a reserved number, is admitted",
        ( if Field(["splice_field" - j_int(260i64)]) = sf_field(260u32)
          then yes else no ), !T, !IO),
    % The band's low end, 256, is the SchemaDef's number, so only its high end
    % is a free number to admit; 256 is the registry case below.
    check("RCTS.1.2.20:the band's high end, 2047, is admitted",
        ( if Field(["splice_field" - j_int(2047i64)]) = sf_field(2047u32)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.20:256, the SchemaDef, is a number the registry names",
        ( if Field(["splice_field" - j_int(256i64)]) = sf_refused(Why256),
             string.sub_string_search(Why256, "registry names", _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.20:255, 2048 and 120 are outside the skip band",
        ( if Field(["splice_field" - j_int(255i64)]) = sf_refused(_),
             Field(["splice_field" - j_int(2048i64)]) = sf_refused(_),
             Field(["splice_field" - j_int(120i64)]) = sf_refused(_)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.20:258, the StreamHeader, is a number the registry names",
        ( if Field(["splice_field" - j_int(258i64)]) = sf_refused(Why258),
             string.sub_string_search(Why258, "registry names", _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.20:a string is not an integer",
        ( if Field(["splice_field" - j_string("260")]) = sf_refused(_)
          then yes else no ), !T, !IO),
    Passed = (func(K) = behave_result(bo_pass, K, "")),
    check("RCTS.1.2.20:the field on another kind fails",
        ( if splice_field_placed("replay_determinism",
                object(["splice_field" - j_int(2000i64)]),
                Passed("replay_determinism")) ^ br_outcome = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.20:and on `rfcs_roundtrip` it stands",
        ( if splice_field_placed("rfcs_roundtrip",
                object(["splice_field" - j_int(2000i64)]),
                Passed("rfcs_roundtrip")) ^ br_outcome = bo_pass
          then yes else no ), !T, !IO).

    % [RCTS.1.2.21]: `expect.tamper` is `runtime_error`'s,
    % `replay_determinism`'s and `runtime_fact_count`'s alone. On
    % `replay_determinism` it is `drop_call_operand` alone, the one edit whose
    % artefact loads. On `runtime_fact_count` it is anything but a string,
    % whose artefact is refused for its hash, and `drop_call_operand`, whose
    % fault is a step's.
    %
:- func tamper_placed(string, json_members, behave_result) = behave_result.

tamper_placed(Kind, Expect, Result0) =
    ( if
        lookup_member(Expect, "tamper", TamperJ),
        Kind \= "runtime_error",
        not tamper_admitted(Kind, TamperJ)
    then
        ( if Kind = "replay_determinism" then
            behave_result(bo_fail, Kind, "expect.tamper on "
                ++ "`replay_determinism` is `drop_call_operand` alone "
                ++ "([RCTS.1.2.21]); got " ++ string.string(TamperJ))
        else if Kind = "runtime_fact_count" then
            behave_result(bo_fail, Kind, "expect.tamper on "
                ++ "`runtime_fact_count` is an object other than "
                ++ "`drop_call_operand`, or a list ([RCTS.1.2.21]); got "
                ++ string.string(TamperJ))
        else
            behave_result(bo_fail, Kind, "expect.tamper is `runtime_error`'s, "
                ++ "`replay_determinism`'s and `runtime_fact_count`'s alone "
                ++ "([RCTS.1.2.21]); this fixture's kind is `" ++ Kind ++ "`")
        )
    else
        Result0
    ).

    % The `tamper` a kind other than `runtime_error` takes ([RCTS.1.2.21]).
    %
:- pred tamper_admitted(string::in, json::in) is semidet.

tamper_admitted(Kind, TamperJ) :-
    (
        Kind = "replay_determinism",
        drop_call_operand_tamper(TamperJ)
    ;
        Kind = "runtime_fact_count",
        not TamperJ = j_string(_),
        not drop_call_operand_tamper(TamperJ)
    ).

:- pred drop_call_operand_tamper(json::in) is semidet.

drop_call_operand_tamper(j_object(O)) :-
    members(O) = ["drop_call_operand" - _].

    % [RCTS.1.2.25], [RCTS.1.2.26], [RCTS.1.2.31]: a field one kind alone
    % reads fails a fixture of any other kind, and a fixture whose fields are
    % not of the types its clause states fails, whatever its run gave.
    %
:- func kind_fields_placed(string, json_members, behave_result)
    = behave_result.

kind_fields_placed(Kind, Expect, Result0) = Result :-
    ( if
        Kind \= "runtime_error",
        list.find_first_match(
            (pred(F::in) is semidet :- lookup_member(Expect, F, _)),
            runtime_error_fields, Field)
    then
        Result = behave_result(bo_fail, Kind, "expect." ++ Field
            ++ " is `runtime_error`'s alone ([RCTS.1.2.25]); this fixture's "
            ++ "kind is `" ++ Kind ++ "`")
    else if
        Kind \= "introspection_assert",
        lookup_member(Expect, "add_schema_ref", _)
    then
        Result = behave_result(bo_fail, Kind, "expect.add_schema_ref is "
            ++ "`introspection_assert`'s alone ([RCTS.1.2.26]); this "
            ++ "fixture's kind is `" ++ Kind ++ "`")
    else if
        Kind \= "runtime_fact_count",
        lookup_member(Expect, "add_compiled_code", _)
    then
        Result = behave_result(bo_fail, Kind, "expect.add_compiled_code is "
            ++ "`runtime_fact_count`'s alone ([RCTS.1.2.31]); this "
            ++ "fixture's kind is `" ++ Kind ++ "`")
    else if rcts_1_2_30_refusal(Kind, Expect) = Why then
        Result = behave_result(bo_fail, Kind, Why)
    else if Kind = "runtime_error", rcts_1_2_25_refusal(Expect) = Why then
        Result = behave_result(bo_fail, Kind, "malformed fixture: " ++ Why)
    else if
        Kind = "introspection_assert",
        rcts_1_2_26_refusal(Expect) = Why
    then
        Result = behave_result(bo_fail, Kind, "malformed fixture: " ++ Why)
    else if
        ( Kind = "runtime_fact_count" ; Kind = "temporal_sequence" ),
        rcts_1_2_31_refusal(Kind, Expect) = Why
    then
        Result = behave_result(bo_fail, Kind, "malformed fixture: " ++ Why)
    else if rcts_1_2_32_refusal(Kind, Expect) = Why then
        Result = behave_result(bo_fail, Kind, "malformed fixture: " ++ Why)
    else if rcts_1_2_33_refusal(Kind, Expect) = Why then
        Result = behave_result(bo_fail, Kind, "malformed fixture: " ++ Why)
    else
        Result = Result0
    ).

    % [RCTS.1.2.30]: why a fixture's `expect.expected_pump_statuses` is
    % refused: the field is `adapter_calls`'s, `replay_determinism`'s and the
    % cross-tier kinds' alone, not beside `tamper`, and it is an array of
    % integers each 0 or less, one for each `pump` step (a cross-tier
    % fixture's on every engine). Fails when the fixture carries no such
    % field, and when it carries a well-formed one.
    %
:- func rcts_1_2_30_refusal(string, json_members) = string is semidet.

rcts_1_2_30_refusal(Kind, Expect) = Why :-
    lookup_member(Expect, "expected_pump_statuses", J),
    ( if
        Kind \= "adapter_calls",
        Kind \= "replay_determinism",
        not cross_tier_kind(Kind)
    then
        Why = "expect.expected_pump_statuses is `adapter_calls`'s, "
            ++ "`replay_determinism`'s and the cross-tier kinds' alone "
            ++ "([RCTS.1.2.30]); this fixture's kind is `" ++ Kind ++ "`"
    else if Kind = "replay_determinism", lookup_member(Expect, "tamper", _) then
        Why = "expect.expected_pump_statuses is not for a fixture that "
            ++ "carries `tamper` ([RCTS.1.2.30])"
    else if pump_status_array(J, Want) then
        Pumps = list.length(list.filter(pump_step,
            array_member(Expect, "steps"))),
        list.length(Want) \= Pumps,
        Why = string.format("expect.expected_pump_statuses has %d entries "
            ++ "for %d `pump` steps ([RCTS.1.2.30])",
            [i(list.length(Want)), i(Pumps)])
    else
        Why = "expect.expected_pump_statuses is not an array of integers "
            ++ "each 0 or less ([RCTS.1.2.30])"
    ).

    % [RCTS.1.2.25]: the fields `runtime_error` alone reads. Its `code`,
    % `message_contains` and `cache_seeds` are other kinds' too.
    %
:- func runtime_error_fields = list(string).

runtime_error_fields =
    ["fault_at", "no_fault_events", "fault_events", "cache_cap",
     "halted_fault", "last_event"].

    % [RCTS.1.2.25]'s `message_contains`: a string, or a non-empty array of
    % strings.
    %
:- pred message_contains_shape(json::in) is semidet.

message_contains_shape(j_string(_)).
message_contains_shape(j_array(Js)) :-
    Js = [_ | _],
    list.all_true((pred(J::in) is semidet :- J = j_string(_)), Js).

    % The strings a fixture's `message_contains` asks the refusal's text to
    % contain: one for a string, each for an array, none when it is absent.
    % `rcts_1_2_25_refusal` has already refused any other shape.
    %
:- func message_wants(json_members) = list(string).

message_wants(Expect) = Wants :-
    ( if lookup_member(Expect, "message_contains", MJ) then
        ( if MJ = j_string(S) then
            Wants = [S]
        else if MJ = j_array(Js) then
            Wants = list.filter_map((func(J) = S is semidet :- J = j_string(S)),
                Js)
        else
            Wants = []
        )
    else
        Wants = []
    ).

:- pred contains_all(string::in, list(string)::in) is semidet.

contains_all(Text, Wants) :-
    list.all_true((pred(W::in) is semidet :- string.sub_string_search(Text, W, _)),
        Wants).

    % [RCTS.1.2.25]: why a `runtime_error` fixture's fields are refused:
    % `code` is required, `steps` excludes `asserts` and `pump`, and each
    % field is of the type the clause states. Fails when the fields are well
    % formed.
    %
:- func rcts_1_2_25_refusal(json_members) = string is semidet.

rcts_1_2_25_refusal(Expect) = Why :-
    ( if
        not (
            lookup_member(Expect, "code", CodeJ),
            CodeJ = j_string(Code),
            negative_code(Code)
        )
    then
        Why0 = "expect.code is not a negative integer in a string"
    else if
        lookup_member(Expect, "message_contains", MJ),
        not message_contains_shape(MJ)
    then
        Why0 = "expect.message_contains is not a string or a non-empty "
            ++ "array of strings"
    else if
        lookup_member(Expect, "steps", _),
        ( lookup_member(Expect, "asserts", _)
        ; lookup_member(Expect, "pump", _)
        )
    then
        Why0 = "expect.steps is given with expect.asserts or expect.pump"
    else if
        list.find_first_match(
            (pred(AF::in) is semidet :-
                lookup_member(Expect, AF, AJ), not object_array(AJ)),
            ["steps", "asserts"], ArrayField)
    then
        Why0 = "expect." ++ ArrayField ++ " is not an array of objects"
    else if
        list.find_first_match(
            (pred(BF::in) is semidet :-
                lookup_member(Expect, BF, BJ), not BJ = j_bool(_)),
            ["pump", "no_fault_events"], BoolField)
    then
        Why0 = "expect." ++ BoolField ++ " is not a boolean"
    else if
        lookup_member(Expect, "cache_seeds", SJ),
        not ( SJ = j_array(Seeds), list.all_true(cache_seed_shape, Seeds) )
    then
        Why0 = "expect.cache_seeds is not an array of "
            ++ cache_seeds_shape_text
    else if
        lookup_member(Expect, "cache_cap", CJ),
        not (
            CJ = j_object(Cap),
            list.all_true(cache_cap_member, members(Cap))
        )
    then
        Why0 = "expect.cache_cap is not an object of `keys` and `bytes`, "
            ++ "non-negative integers"
    else if
        list.find_first_match(
            (pred(NF::in) is semidet :-
                lookup_member(Expect, NF, NJ), not count_json(NJ)),
            ["fault_at", "fact_count_after"], CountField)
    then
        Why0 = "expect." ++ CountField ++ " is not a non-negative integer"
    else if
        lookup_member(Expect, "fault_events", FJ),
        not ( FJ = j_array(Faults), list.all_true(fault_event_name, Faults) )
    then
        Why0 = "expect.fault_events is not an array of bounds_error, "
            ++ "computation_error, engine_error, type_error"
    else if
        lookup_member(Expect, "halted_fault", HJ),
        not HJ = j_string(_)
    then
        Why0 = "expect.halted_fault is not a string"
    else if
        lookup_member(Expect, "last_event", LJ),
        not fault_event_name(LJ)
    then
        Why0 = "expect.last_event is not one of bounds_error, "
            ++ "computation_error, engine_error, type_error"
    else
        % Working memory is unreadable on a halted engine ([LERR.1.4.7],
        % [NCBK.2.9]).
        lookup_member(Expect, "halted_fault", _),
        lookup_member(Expect, "fact_count_after", _),
        Why0 = "expect.fact_count_after reads working memory, which a "
            ++ "halted engine does not have, and the fixture pins a halt "
            ++ "with expect.halted_fault"
    ),
    Why = Why0 ++ " ([RCTS.1.2.25])".

    % `-` and a decimal integer with no leading zero: a status as the
    % negative integer in a string.
    %
:- pred negative_code(string::in) is semidet.

negative_code(Text) :-
    string.remove_prefix("-", Text, Digits),
    string.to_char_list(Digits) = [First | Rest],
    First \= '0',
    char.is_digit(First),
    list.all_true(char.is_digit, Rest).

:- pred object_array(json::in) is semidet.

object_array(j_array(Js)) :-
    list.all_true((pred(J::in) is semidet :- J = j_object(_)), Js).

:- pred count_json(json::in) is semidet.

count_json(j_int(N)) :-
    N >= 0i64.

    % [RCTS.1.2.25]'s `cache_seeds` entry: a `key` string and exactly one of
    % `value`, any JSON value; `text`, a string handed over as written; and
    % `text_bytes`, handed over as those octets ([LSTR.8.5]).
    %
:- pred cache_seed_shape(json::in) is semidet.

cache_seed_shape(j_object(S)) :-
    Keys = list.sort(assoc_list.keys(members(S))),
    lookup_member(S, "key", KJ),
    KJ = j_string(_),
    (
        Keys = ["key", "value"]
    ;
        Keys = ["key", "text"],
        lookup_member(S, "text", j_string(_))
    ;
        Keys = ["key", "text_bytes"],
        lookup_member(S, "text_bytes", HJ),
        HJ = j_string(Hex),
        text_octets(Hex)
    ).

:- func cache_seeds_shape_text = string.

cache_seeds_shape_text =
    "{\"key\": K, \"value\": V}, {\"key\": K, \"text\": T} or "
        ++ "{\"key\": K, \"text_bytes\": H}, K and T strings, H two hex "
        ++ "digits per octet, none of them 00".

    % Text as hex octets ([RCTS.1.2.25]'s `text_bytes`, [RCTS.1.2.28]'s
    % `$text_bytes`): two hex digits per octet, none of them `00`. A U+0000
    % is [LSTR.1.5]'s refusal, which `text_of_octets` cannot build, so the
    % fixture fails at the shape check.
    %
:- pred text_octets(string::in) is semidet.

text_octets(Hex) :-
    hex_bytes(Hex, Octets),
    not list.member(0u8, Octets).

    % Text from octets written as two hex digits each, kept as they are
    % whether or not they are well-formed UTF-8, so a fixture can hand the
    % engine text [LSTR.8.5] refuses. Fails on a malformed hex string, and on
    % a NUL, which no `string` holds ([LSTR.1.1]).
    %
:- pred text_of_octets(string::in, string::out) is semidet.

text_of_octets(Hex, Text) :-
    hex_bytes(Hex, Octets),
    string.from_code_unit_list_allow_ill_formed(
        list.map(uint8.to_int, Octets), Text).

:- pred cache_cap_member(pair(string, json)::in) is semidet.

cache_cap_member(Name - Value) :-
    ( Name = "keys" ; Name = "bytes" ),
    count_json(Value).

:- pred fault_event_name(json::in) is semidet.

fault_event_name(j_string(Name)) :-
    ( Name = "type_error" ; Name = "bounds_error" ; Name = "engine_error"
    ; Name = "computation_error"
    ).

    % [RCTS.1.2.31]: why a `runtime_fact_count` or `temporal_sequence`
    % fixture's fields are refused: `fact_count_after` is required and a
    % non-negative integer, and `runtime_fact_count`'s four inputs are each
    % of the type the clause states. Fails when the fields are well formed.
    %
:- func rcts_1_2_31_refusal(string, json_members) = string is semidet.

rcts_1_2_31_refusal(Kind, Expect) = Why :-
    ( if
        not (
            lookup_member(Expect, "fact_count_after", NJ),
            count_json(NJ)
        )
    then
        Why0 = "expect.fact_count_after is not a non-negative integer"
    else
        Kind = "runtime_fact_count",
        ( if
            lookup_member(Expect, "cache_seeds", SJ),
            not ( SJ = j_array(Seeds), list.all_true(cache_seed_shape, Seeds) )
        then
            Why0 = "expect.cache_seeds is not an array of "
                ++ cache_seeds_shape_text
        else if
            lookup_member(Expect, "asserts", AJ),
            not ( AJ = j_array(As), list.all_true(fact_assert_shape, As) )
        then
            Why0 = "expect.asserts is not an array of objects of `schema`, "
                ++ "a string, and an optional `slots`, an object"
        else if
            lookup_member(Expect, "generate_asserts", GJ),
            not ( GJ = j_array(Gs), list.all_true(generate_shape, Gs) )
        then
            Why0 = "expect.generate_asserts is not an array of objects of "
                ++ "`schema` and `slot_name`, strings, `count`, a "
                ++ "non-negative integer, and an optional `start`, an integer"
        else if
            lookup_member(Expect, "pump", PJ),
            not PJ = j_bool(_)
        then
            Why0 = "expect.pump is not a boolean"
        else
            lookup_member(Expect, "add_compiled_code", CJ),
            not add_compiled_code_shape(CJ, _),
            Why0 = "expect.add_compiled_code is not an object of one member, "
                ++ "`node`, an integer of at least 1"
        )
    ),
    Why = Why0 ++ " ([RCTS.1.2.31])".

    % [RCTS.1.2.32]: why an event-list fixture's array, or any fixture's
    % `wall_clock`, is refused: `wall_clock` is the string "unset", on a
    % `logical` kind alone, and an event-list kind's array is required and an
    % array of strings. Fails when the fields are well formed.
    %
:- func rcts_1_2_32_refusal(string, json_members) = string is semidet.

rcts_1_2_32_refusal(Kind, Expect) = Why :-
    ( if
        lookup_member(Expect, "wall_clock", _),
        not logical_kind(Kind)
    then
        Why0 = "expect.wall_clock is a `logical` kind's alone; this "
            ++ "fixture's kind is `" ++ Kind ++ "`"
    else if
        lookup_member(Expect, "wall_clock", WallJ),
        not WallJ = j_string("unset")
    then
        Why0 = "expect.wall_clock is not \"unset\""
    else
        event_list_field(Kind, Field),
        not (
            lookup_member(Expect, Field, ListJ),
            ListJ = j_array(Items),
            list.all_true((pred(I::in) is semidet :- I = j_string(_)), Items)
        ),
        Why0 = "expect." ++ Field ++ " is not an array of strings"
    ),
    Why = Why0 ++ " ([RCTS.1.2.32])".

    % [RCTS.1.2.33]: why an `event_seq_monotonic` or `header_field_eq`
    % fixture's fields are refused. Fails when the fields are well formed.
    %
:- func rcts_1_2_33_refusal(string, json_members) = string is semidet.

rcts_1_2_33_refusal(Kind, Expect) = Why :-
    ( if Kind = "event_seq_monotonic" then
        ( if
            lookup_member(Expect, "filter_kind", FJ),
            not FJ = j_string(_)
        then
            Why0 = "expect.filter_kind is not a string"
        else if
            lookup_member(Expect, "min_events", MJ),
            not count_json(MJ)
        then
            Why0 = "expect.min_events is not a non-negative integer"
        else if
            lookup_member(Expect, "expected_seq_step", SJ),
            not positive_json(SJ)
        then
            Why0 = "expect.expected_seq_step is not a positive integer"
        else
            lookup_member(Expect, "expected_clocks", CJ),
            not ( CJ = j_array(Cs), list.all_true(count_json, Cs) ),
            Why0 = "expect.expected_clocks is not an array of non-negative "
                ++ "integers"
        )
    else
        Kind = "header_field_eq",
        not (
            lookup_member(Expect, "checks", KJ),
            KJ = j_array(Ks),
            Ks = [_ | _],
            list.all_true(header_check_shape, Ks)
        ),
        Why0 = "expect.checks is not a non-empty array of header checks, "
            ++ "each `field`, one of ds_version, session_id, tier_id, "
            ++ "dsc_hash, and exactly one of `equals`, a string, on a text "
            ++ "field, `present`, a boolean, and `byte_len`, a non-negative "
            ++ "integer, on dsc_hash"
    ),
    Why = Why0 ++ " ([RCTS.1.2.33])".

:- pred positive_json(json::in) is semidet.

positive_json(j_int(N)) :-
    N > 0i64.

    % One `header_field_eq` check: `field` and exactly one assertion, of its
    % type, on a field it applies to ([RCTS.1.2.33]).
    %
:- pred header_check_shape(json::in) is semidet.

header_check_shape(j_object(Ms)) :-
    lookup_member(Ms, "field", FJ),
    FJ = j_string(Field),
    header_field_name(Field),
    Names = list.sort(assoc_list.keys(members(Ms))),
    ( if Names = ["equals", "field"] then
        Field \= "dsc_hash",
        lookup_member(Ms, "equals", EJ),
        EJ = j_string(_)
    else if Names = ["field", "present"] then
        lookup_member(Ms, "present", PJ),
        PJ = j_bool(_)
    else
        Names = ["byte_len", "field"],
        Field = "dsc_hash",
        lookup_member(Ms, "byte_len", BJ),
        count_json(BJ)
    ).

    % [RCTS.1.2.33]: the session header fields a check may name, the ones
    % every runtime's header reports. `runner.py`'s `HEADER_FIELDS`.
    %
:- pred header_field_name(string::in) is semidet.

header_field_name("ds_version").
header_field_name("session_id").
header_field_name("tier_id").
header_field_name("dsc_hash").

    % [RCTS.1.2.10]: the kinds whose category is `logical`. `runner.py`'s
    % `LOGICAL_KINDS`.
    %
:- pred logical_kind(string::in) is semidet.

logical_kind("event_sequence").
logical_kind("event_sequence_strict").
logical_kind("event_seq_monotonic").
logical_kind("event_kinds_forbidden").
logical_kind("rule_fire_order").
logical_kind("log_message_sequence").
logical_kind("header_field_eq").
logical_kind("introspection_assert").

    % [RCTS.1.2.32]: each event-list kind and the array of strings it compares
    % with the run. `runner.py`'s `EVENT_LIST_FIELDS`.
    %
:- pred event_list_field(string::in, string::out) is semidet.

event_list_field("rule_fire_order", "expected_rule_names").
event_list_field("log_message_sequence", "expected_messages").
event_list_field("event_sequence", "expected_kinds").
event_list_field("event_sequence_strict", "expected_kinds").
event_list_field("event_kinds_forbidden", "forbidden_kinds").

    % A `runtime_fact_count` fixture's `asserts` entry: `schema`, a string, and
    % an optional `slots`, an object ([RCTS.1.2.31]).
    %
:- pred fact_assert_shape(json::in) is semidet.

fact_assert_shape(j_object(Ms)) :-
    lookup_member(Ms, "schema", SJ),
    SJ = j_string(_),
    ( if lookup_member(Ms, "slots", SlotsJ) then
        SlotsJ = j_object(_)
    else
        true
    ).

    % A `generate_asserts` entry: `schema` and `slot_name`, strings, `count`,
    % a non-negative integer, and an optional `start`, an integer
    % ([RCTS.1.2.31]).
    %
:- pred generate_shape(json::in) is semidet.

generate_shape(j_object(Ms)) :-
    lookup_member(Ms, "schema", SJ),
    SJ = j_string(_),
    lookup_member(Ms, "slot_name", NJ),
    NJ = j_string(_),
    lookup_member(Ms, "count", CJ),
    count_json(CJ),
    ( if lookup_member(Ms, "start", BJ) then
        BJ = j_int(_)
    else
        true
    ).

    % [RCTS.1.2.26]: why an `introspection_assert` fixture is refused:
    % `checks` is a non-empty array, each check names a surface of the set and
    % carries exactly that surface's members, each of its type, and
    % `add_schema_ref` is three strings. Fails when the fixture is well formed.
    %
:- func rcts_1_2_26_refusal(json_members) = string is semidet.

rcts_1_2_26_refusal(Expect) = Why :-
    Checks = array_member(Expect, "checks"),
    ( if
        not (
            lookup_member(Expect, "checks", CJ),
            object_array(CJ),
            Checks = [_ | _]
        )
    then
        Why0 = "expect.checks is not a non-empty array of objects"
    else if list.find_first_map(check_refusal, Checks, CheckWhy) then
        Why0 = CheckWhy
    else
        lookup_member(Expect, "add_schema_ref", RefJ),
        not add_schema_ref_shape(RefJ),
        Why0 = "expect.add_schema_ref is not {\"schema\", \"slot\", \"ref\"} "
            ++ "of three strings"
    ),
    Why = Why0 ++ " ([RCTS.1.2.26])".

    % Why one introspection check is refused. Fails when it is well formed.
    %
:- pred check_refusal(json::in, string::out) is semidet.

check_refusal(Check, Why) :-
    ( if
        Check = j_object(Ms),
        lookup_member(Ms, "surface", SJ),
        SJ = j_string(Surface),
        surface_members(Surface, Takes)
    then
        % The predicate forms throughout: `list.sort(A) = list.sort(B)` is
        % ambiguous between two lists and two curried predicates.
        assoc_list.keys(Takes, Names),
        assoc_list.keys(members(Ms), Given),
        list.sort(Given, SortedGiven),
        list.sort(["surface" | Names], SortedWanted),
        list.sort(Names, SortedNames),
        not (
            SortedGiven = SortedWanted,
            list.all_true(
                (pred(P::in) is semidet :-
                    P = Name - Type,
                    lookup_member(Ms, Name, V),
                    of_member_type(Type, V)),
                Takes)
        ),
        Why = "introspection check `" ++ Surface ++ "` takes exactly "
            ++ string.join_list(", ", SortedNames) ++ ", of their types"
    else
        Why = "introspection check names no surface of the set"
    ).

:- type member_type
    --->    mt_count
    ;       mt_positive
    ;       mt_strings
    ;       mt_string
    ;       mt_string_or_null.

    % [RCTS.1.2.26]'s closed set: each surface, and the members a check of it
    % takes. `runner.py`'s `_SURFACES` is the same table.
    %
:- pred surface_members(string::in, assoc_list(string, member_type)::out)
    is semidet.

surface_members("fact_count", ["equals" - mt_count]).
surface_members("justifiers",
    ["fact_id" - mt_positive, "expect_rules" - mt_strings]).
surface_members("justifier_count", ["fact_id" - mt_positive, "count" - mt_count]).
surface_members("rete_network", ["min_nodes" - mt_count, "min_edges" - mt_count]).
surface_members("slot_schema_ref",
    ["schema" - mt_string, "slot" - mt_string, "equals" - mt_string_or_null]).

:- pred of_member_type(member_type::in, json::in) is semidet.

of_member_type(mt_count, J) :-
    count_json(J).
of_member_type(mt_positive, j_int(N)) :-
    N >= 1i64.
of_member_type(mt_strings, j_array(Js)) :-
    list.all_true((pred(J::in) is semidet :- J = j_string(_)), Js).
of_member_type(mt_string, j_string(_)).
of_member_type(mt_string_or_null, J) :-
    ( J = j_null ; J = j_string(_) ).

:- pred add_schema_ref_shape(json::in) is semidet.

add_schema_ref_shape(j_object(Ms)) :-
    list.sort(assoc_list.keys(members(Ms))) = ["ref", "schema", "slot"],
    list.all_true(
        (pred(P::in) is semidet :- P = _ - V, V = j_string(_)),
        members(Ms)).

    % [RCTS.1.2.23]: the recording fields are `rfcs_roundtrip`'s alone, but
    % `replay_refused` reads `late_start` too ([RCTS.1.2.18]). So is a step's
    % `refused` ([RCTS.1.2.27]).
    %
:- func recording_fields_placed(string, json_members, behave_result)
    = behave_result.

recording_fields_placed(Kind, Expect, Result0) = Result :-
    ( if
        Kind \= "rfcs_roundtrip",
        list.find_first_match(
            (pred(F::in) is semidet :- lookup_member(Expect, F, _)),
            recording_fields, Field)
    then
        Result = behave_result(bo_fail, Kind, "expect." ++ Field
            ++ " is `rfcs_roundtrip`'s alone ([RCTS.1.2.23]); this fixture's "
            ++ "kind is `" ++ Kind ++ "`")
    else if
        Kind \= "rfcs_roundtrip",
        Kind \= "replay_refused",
        lookup_member(Expect, "late_start", _)
    then
        Result = behave_result(bo_fail, Kind, "expect.late_start is "
            ++ "`rfcs_roundtrip`'s and `replay_refused`'s alone "
            ++ "([RCTS.1.2.23]); this fixture's kind is `" ++ Kind ++ "`")
    else if rcts_1_2_27_refusal(Kind, Expect) = yes(Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else
        Result = Result0
    ).

    % [RCTS.1.2.27]: why a fixture's `refused` steps fail it, or `no`:
    % `refused` is `rfcs_roundtrip`'s alone, on an `assert` step, and a
    % string.
    %
:- func rcts_1_2_27_refusal(string, json_members) = maybe(string).

rcts_1_2_27_refusal(Kind, Expect) = Refusal :-
    Reasons = list.filter_map(refused_step_reason(Kind),
        array_member(Expect, "steps")),
    (
        Reasons = [Why | _],
        Refusal = yes(Why)
    ;
        Reasons = [],
        Refusal = no
    ).

    % Why one step's `refused` fails its fixture; fails for a step that
    % carries none, or carries it as [RCTS.1.2.27] admits.
    %
:- func refused_step_reason(string, json) = string is semidet.

refused_step_reason(Kind, j_object(Ms)) = Why :-
    lookup_member(Ms, "refused", RefusedJ),
    ( if Kind \= "rfcs_roundtrip" then
        Why = "a step's `refused` is `rfcs_roundtrip`'s alone "
            ++ "([RCTS.1.2.27]); this fixture's kind is `" ++ Kind ++ "`"
    else if not (lookup_member(Ms, "op", OpJ), OpJ = j_string("assert")) then
        Why = "a step's `refused` is on a step that is not an `assert`; "
            ++ "only an `assert` takes it ([RCTS.1.2.27])"
    else
        not RefusedJ = j_string(_),
        Why = "a step's `refused` is not a string ([RCTS.1.2.27])"
    ).

    % [RCTS.1.2.28], [RCTS.1.2.29]: a fixture whose steps break the step
    % vocabulary fails, whatever its run would have said. A deprecated
    % fixture never reaches here (`classify`).
    %
:- func steps_placed(json_members, json_members, string, behave_result)
    = behave_result.

steps_placed(Members, Expect, Kind, Result0) = Result :-
    ( if lookup_member(Members, "category", CatJ), CatJ = j_string(C) then
        Category = C
    else
        Category = ""
    ),
    ( if rcts_1_2_28_refusal(Category, Expect) = yes(Why) then
        Result = behave_result(bo_fail, Kind, Why)
    else
        Result = Result0
    ).

    % Why a fixture's steps fail it, or `no`: every step's `op` names one of
    % `step_ops`, with exactly the members it takes, each of its type; a
    % cross-tier fixture's `engines` is an object of programs, and its steps
    % name them.
    %
:- func rcts_1_2_28_refusal(string, json_members) = maybe(string).

rcts_1_2_28_refusal(Category, Expect) = Refusal :-
    Cross = ( if Category = "cross-tier" then yes else no ),
    ( if Cross = yes, not engines_shape(Expect, _) then
        Refusal = yes("expect.engines is not an object of "
            ++ "{\"rules_ds\": <string>}, each with an optional "
            ++ "\"wall_clock\": \"unset\" ([RCTS.1.2.29])")
    else if Cross = no, lookup_member(Expect, "engines", _) then
        Refusal = yes("expect.engines is a cross-tier fixture's alone "
            ++ "([RCTS.1.2.29]); this fixture is `" ++ Category ++ "`")
    else
        Labels = ( if engines_shape(Expect, Ls) then Ls else [] ),
        Reasons = list.filter_map(steps_array_reason(Cross, Labels, Expect),
            ["steps", "after_clone", "after_free"]),
        (
            Reasons = [Why | _],
            Refusal = yes(Why)
        ;
            Reasons = [],
            Refusal = rcts_1_2_29_published_at_refusal(Cross, Category,
                Labels, Expect)
        )
    ).

    % [RCTS.1.2.29]: why a fixture's `expect.expected_published_asserted_at`
    % is refused, or `no`: it is a cross-tier fixture's alone, an object
    % whose every member names an engine of `engines` and is an array of
    % integers and nulls. `runner.py`'s `_published_asserted_at_refusal`
    % refuses the same fixtures.
    %
:- func rcts_1_2_29_published_at_refusal(bool, string, list(string),
    json_members) = maybe(string).

rcts_1_2_29_published_at_refusal(Cross, Category, Labels, Expect) = Refusal :-
    ( if lookup_member(Expect, "expected_published_asserted_at", J) then
        ( if Cross = no then
            Refusal = yes("expect.expected_published_asserted_at is a "
                ++ "cross-tier fixture's alone ([RCTS.1.2.29]); this fixture "
                ++ "is `" ++ Category ++ "`")
        else if published_at_shape(J, Want) then
            ( if
                list.find_first_match(
                    (pred(LW::in) is semidet :-
                        LW = L - _,
                        not list.member(L, Labels)),
                    Want, Unknown - _)
            then
                Refusal = yes("expect.expected_published_asserted_at names "
                    ++ "no engine of expect.engines: `" ++ Unknown
                    ++ "` ([RCTS.1.2.29])")
            else
                Refusal = no
            )
        else
            Refusal = yes("expect.expected_published_asserted_at is not an "
                ++ "object of arrays of integers and nulls ([RCTS.1.2.29])")
        )
    else
        Refusal = no
    ).

    % An `expected_published_asserted_at` of [RCTS.1.2.29]'s shape: per
    % engine label, its entries, `no` for a null.
    %
:- pred published_at_shape(json::in,
    assoc_list(string, list(maybe(int64)))::out) is semidet.

published_at_shape(j_object(Obj), Want) :-
    list.map(
        (pred(LJ::in, LE::out) is semidet :-
            LJ = Label - EntriesJ,
            EntriesJ = j_array(Js),
            list.map(published_at_entry, Js, Entries),
            LE = Label - Entries),
        members(Obj), Want).

:- pred published_at_entry(json::in, maybe(int64)::out) is semidet.

published_at_entry(j_int(N), yes(N)).
published_at_entry(j_null, no).

    % A cross-tier fixture's engine labels, when `engines` is an object of at
    % least one member, each an object of `rules_ds`, a string, and
    % optionally `wall_clock`, the string "unset" ([RCTS.1.2.29]).
    %
:- pred engines_shape(json_members::in, list(string)::out) is semidet.

engines_shape(Expect, Labels) :-
    lookup_member(Expect, "engines", EnginesJ),
    EnginesJ = j_object(EnginesMs),
    Decls = members(EnginesMs),
    Decls = [_ | _],
    list.all_true(
        (pred(Decl::in) is semidet :-
            Decl = _ - DeclJ,
            DeclJ = j_object(DeclMs),
            Keys = assoc_list.keys(members(DeclMs)),
            ( Keys = ["rules_ds"]
            ; Keys = ["rules_ds", "wall_clock"],
              lookup_member(DeclMs, "wall_clock", j_string("unset"))
            ),
            lookup_member(DeclMs, "rules_ds", SourceJ),
            SourceJ = j_string(_)),
        Decls),
    Labels = assoc_list.keys(Decls).

    % Why one array of steps fails its fixture; fails when it is well formed
    % or absent.
    %
:- func steps_array_reason(bool, list(string), json_members, string) = string
    is semidet.

steps_array_reason(Cross, Labels, Expect, Name) = Why :-
    lookup_member(Expect, Name, StepsJ),
    ( if StepsJ = j_array(Steps) then
        Why = first_step_reason(Cross, Labels, Name, 0, Steps)
    else
        Why = "expect." ++ Name ++ " is not an array of objects "
            ++ "([RCTS.1.2.28])"
    ).

:- func first_step_reason(bool, list(string), string, int, list(json))
    = string is semidet.

first_step_reason(Cross, Labels, Name, I, [Step | Steps]) = Why :-
    ( if step_reason(Cross, Labels, Step) = Reason then
        Why = Name ++ "[" ++ string.int_to_string(I) ++ "]" ++ Reason
    else
        Why = first_step_reason(Cross, Labels, Name, I + 1, Steps)
    ).

    % Why one step breaks the vocabulary; fails for a step that keeps it.
    %
:- func step_reason(bool, list(string), json) = string is semidet.

step_reason(Cross, Labels, StepJ) = Why :-
    ( if StepJ = j_object(Ms) then
        ( if
            Cross = yes,
            not (
                lookup_member(Ms, "engine", EngineJ),
                EngineJ = j_string(Label),
                list.member(Label, Labels)
            )
        then
            Why = ".engine names no engine of expect.engines ([RCTS.1.2.29])"
        else if Cross = no, lookup_member(Ms, "engine", _) then
            Why = ".engine is a cross-tier fixture's alone ([RCTS.1.2.29])"
        else if
            lookup_member(Ms, "op", OpJ),
            OpJ = j_string(Op),
            assoc_list.search(step_ops(Cross), Op, Takes)
        then
            Given = list.filter(
                (pred(P::in) is semidet :-
                    P = K - _, K \= "op", K \= "engine"),
                members(Ms)),
            ( if Why0 = op_member_reason(Op, Takes, Given, Labels) then
                Why = Why0
            else
                Why = bytes_slot_reason(Given)
            )
        else
            Why = ".op names no step op ([RCTS.1.2.28])"
        )
    else
        Why = " is not an object ([RCTS.1.2.28])"
    ).

    % Why a step of a known op breaks its members; fails when they are as the
    % op takes them.
    %
:- func op_member_reason(string, list(step_member), assoc_list(string, json),
    list(string)) = string is semidet.

op_member_reason(Op, Takes, Given, Labels) = Why :-
    ( if
        list.find_first_match(
            (pred(SM::in) is semidet :-
                SM = sm(N, yes, _),
                not assoc_list.search(Given, N, _)),
            Takes, Lacked),
        Lacked = sm(LackedName, _, _)
    then
        Why = " (`" ++ Op ++ "`) lacks `" ++ LackedName ++ "` ([RCTS.1.2.28])"
    else if
        list.find_first_match(
            (pred(SM::in) is semidet :-
                SM = sm(N, _, T),
                assoc_list.search(Given, N, V),
                not of_step_type(T, V)),
            Takes, Mistyped),
        Mistyped = sm(MistypedName, _, _)
    then
        Why = "." ++ MistypedName ++ " is not of its type ([RCTS.1.2.28])"
    else if
        list.find_first_match(
            (pred(P::in) is semidet :-
                P = K - _,
                not (list.member(SM, Takes), SM = sm(K, _, _))),
            Given, Extra),
        Extra = ExtraName - _
    then
        Why = " (`" ++ Op ++ "`) carries `" ++ ExtraName
            ++ "`, which it does not take ([RCTS.1.2.28])"
    else
        ( Op = "forward" ; Op = "forward_external" ),
        assoc_list.search(Given, "from", FromJ),
        not (FromJ = j_string(From), list.member(From, Labels)),
        Why = ".from names no engine of expect.engines ([RCTS.1.2.29])"
    ).

    % Why a step's `slots` break [RCTS.1.2.28]'s `Bytes` form or its `String`
    % octets form (`off_octets_form`). `slot_value` reads a malformed one as
    % `null`, so it is refused here. Fails when every slot keeps the forms.
    %
:- func bytes_slot_reason(assoc_list(string, json)) = string is semidet.

bytes_slot_reason(Given) = Why :-
    assoc_list.search(Given, "slots", SlotsJ),
    SlotsJ = j_object(SlotsO),
    ( if list.find_first_match(off_octets_form("$bytes"), members(SlotsO), B)
    then
        Form = "$bytes",
        Octets = "two hex digits per octet",
        Bad = B
    else
        list.find_first_match(off_octets_form("$text_bytes"), members(SlotsO),
            Bad),
        Form = "$text_bytes",
        Octets = "two hex digits per octet, none of them 00"
    ),
    Bad = Slot - _,
    Why = ".slots." ++ Slot ++ " is not {\"" ++ Form ++ "\": H}, H "
        ++ Octets ++ " ([RCTS.1.2.28])".

    % A slot value that is an object with a `Form` member and is not
    % exactly `{Form: H}`, H two hex digits per octet, and for `$text_bytes`
    % none of them `00`.
    %
:- pred off_octets_form(string::in, pair(string, json)::in) is semidet.

off_octets_form(Form, P) :-
    P = _ - V,
    V = j_object(VO),
    lookup_member(VO, Form, _),
    not (
        members(VO) = [Form - j_string(Hex)],
        ( if Form = "$text_bytes" then
            text_octets(Hex)
        else
            hex_bytes(Hex, _)
        )
    ).

    % [RCTS.1.2.28]'s ops and the members each takes, `runner.py`'s
    % `_STEP_OPS`; a cross-tier fixture's steps take [RCTS.1.2.29]'s two more.
    %
:- type step_member
    --->    sm(string, bool, step_type).
            % The member's name, whether the op requires it, its type.

:- type step_type
    --->    st_string
    ;       st_object
    ;       st_count
    ;       st_int
    ;       st_any.

:- func step_ops(bool) = assoc_list(string, list(step_member)).

step_ops(Cross) = Base ++ CrossOps :-
    Base = [
        "assert" - [sm("schema", yes, st_string), sm("slots", no, st_object),
            sm("as", no, st_string), sm("corr_from_call", no, st_count),
            sm("refused", no, st_any)],
        "retract" - [sm("label", yes, st_string)],
        "pump" - [],
        "advance" - [sm("delta_ns", yes, st_count)],
        "set" - [sm("now_ns", yes, st_count)],
        "wall_set" - [sm("utc_ns", yes, st_int)],
        % `ttl_ns` is read as an int64, so 0 to 2^63 - 1.
        "cache_seed" - [sm("key", yes, st_string), sm("value", yes, st_any),
            sm("ttl_ns", no, st_count)]
    ],
    (
        Cross = yes,
        CrossOps = [
            "forward" - [sm("from", yes, st_string)],
            "forward_external" - [sm("from", yes, st_string)]
        ]
    ;
        Cross = no,
        CrossOps = []
    ).

    % `test_conformance.py`'s `test_rcts_1_2_28__*` and `test_rcts_1_2_29__*`
    % cases. The steps the runtime refuses run through `classify`, as a
    % corpus file runs.
    % @spec [RCTS.1.2.28]
    %
:- pred step_vocabulary_checks(registry::in, stdlib::in,
    tally::in, tally::out, io::di, io::uo) is det.

step_vocabulary_checks(Registry, Stdlib, !T, !IO) :-
    Step = (func(Pairs) = j_object(object(Pairs))),
    Steps = (func(S) = object(["steps" - j_array([S])])),
    Refused = (pred(Cat::in, Ex::in) is semidet :-
        rcts_1_2_28_refusal(Cat, Ex) = yes(_)),
    Pump = Step(["op" - j_string("pump")]),
    Source = "schema T scope logical:\n    v: Int key\n\n"
        ++ "rule fires:\n    T\n->\n    log info \"a\"\n\n"
        ++ "rule quiet:\n    T t where t.v > 9\n->\n    log info \"b\"\n",
    Live = (func(StepList) = j_object(object([
        "id" - j_string("X"), "category" - j_string("logical"),
        "scenario" - j_string(""), "rules_ds" - j_string(Source),
        "expect" - j_object(object(["kind" - j_string("rule_fire_order"),
            "expected_rule_names" - j_array([]),
            "steps" - j_array(StepList)]))]))),
    FailsLive = (pred(StepList::in, Says::in) is semidet :-
        classify(Registry, Stdlib, [], Live(StepList), R),
        R = behave_result(bo_fail, _, Why),
        string.sub_string_search(Why, Says, _)),
    Seed = Step(["op" - j_string("cache_seed"), "key" - j_string("k"),
        "value" - j_int(1i64)]),
    % The window ends at the engine's first stream event ([NLFC.9.2]), which
    % a host assert emits as a pump does.
    check("RCTS.1.2.28:a cache seed after a pump fails the fixture",
        ( if FailsLive([Pump, Seed], "NLFC.9.2") then yes else no ), !T, !IO),
    check("RCTS.1.2.28:a cache seed after a host assert fails the fixture",
        ( if FailsLive([Step(["op" - j_string("assert"),
                "schema" - j_string("T"),
                "slots" - j_object(object(["v" - j_int(1i64)]))]), Seed],
                "NLFC.9.2")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:a set below the current instant after an input fails",
        ( if FailsLive([Step(["op" - j_string("set"), "now_ns" - j_int(5i64)]),
                Step(["op" - j_string("assert"), "schema" - j_string("T"),
                    "slots" - j_object(object(["v" - j_int(1i64)]))]),
                Pump,
                Step(["op" - j_string("set"), "now_ns" - j_int(0i64)])],
                "NTST.3.1")
          then yes else no ), !T, !IO),
    Assert = (func(V) = Steps(Step(["op" - j_string("assert"),
        "schema" - j_string("T"), "slots" - j_object(object(["b" - V]))]))),
    Bytes = (func(H) = j_object(object(["$bytes" - H]))),
    check("RCTS.1.2.28:a Bytes slot off its form fails",
        ( if Refused("logical", Assert(Bytes(j_string("00 ff")))),
             Refused("logical", Assert(Bytes(j_string("0")))),
             Refused("logical", Assert(Bytes(j_string("zz")))),
             Refused("logical", Assert(Bytes(j_int(5i64)))),
             Refused("logical", Assert(j_object(object([
                "$bytes" - j_string("00"), "x" - j_int(1i64)]))))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:the Bytes form passes",
        ( if rcts_1_2_28_refusal("logical", Assert(Bytes(j_string("00fF"))))
                = no,
             rcts_1_2_28_refusal("logical", Assert(Bytes(j_string("")))) = no
          then yes else no ), !T, !IO),
    % [LSTR.8.5]'s form, held as the `Bytes` form is, with no `00` octet
    % ([LSTR.1.5]).
    TextBytes = (func(H) = j_object(object(["$text_bytes" - H]))),
    check("RCTS.1.2.28:a String octets slot off its form fails",
        ( if Refused("logical", Assert(TextBytes(j_string("c0 af")))),
             Refused("logical", Assert(TextBytes(j_string("c")))),
             Refused("logical", Assert(TextBytes(j_string("zz")))),
             Refused("logical", Assert(TextBytes(j_int(5i64)))),
             Refused("logical", Assert(j_object(object([
                "$text_bytes" - j_string("c0af"), "x" - j_int(1i64)])))),
             Refused("logical", Assert(TextBytes(j_string("00")))),
             Refused("logical", Assert(TextBytes(j_string("c000"))))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:the String octets form passes the shape check",
        ( if rcts_1_2_28_refusal("logical",
                Assert(TextBytes(j_string("c0aF")))) = no,
             rcts_1_2_28_refusal("logical", Assert(TextBytes(j_string(""))))
                = no,
             rcts_1_2_28_refusal("logical",
                Assert(TextBytes(j_string("a00b")))) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:String octets on a slot that is not a String fail",
        ( if FailsLive([Step(["op" - j_string("assert"),
                "schema" - j_string("T"),
                "slots" - j_object(object(["v" - TextBytes(j_string("61"))]))])],
                "RCTS.1.2.28")
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:every op of the set, as it takes its members, passes",
        ( if rcts_1_2_28_refusal("logical", object(["steps" - j_array([
                Step(["op" - j_string("assert"), "schema" - j_string("S"),
                    "slots" - j_object(object([])), "as" - j_string("a"),
                    "corr_from_call" - j_int(0i64)]),
                Step(["op" - j_string("retract"), "label" - j_string("a")]),
                Pump,
                Step(["op" - j_string("advance"), "delta_ns" - j_int(1i64)]),
                Step(["op" - j_string("set"), "now_ns" - j_int(0i64)]),
                Step(["op" - j_string("wall_set"), "utc_ns" - j_int(-1i64)]),
                Step(["op" - j_string("cache_seed"), "key" - j_string("k"),
                    "value" - j_null]),
                Step(["op" - j_string("cache_seed"), "key" - j_string("k"),
                    "value" - j_int(1i64), "ttl_ns" - j_int(0i64)]),
                Step(["op" - j_string("cache_seed"), "key" - j_string("k"),
                    "value" - j_int(1i64), "ttl_ns" - j_int(int64.max_int64)])
             ])])) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:an op the set does not hold fails",
        ( if Refused("logical", Steps(Step(["op" - j_string("deliver")]))),
             Refused("logical", Steps(Step(["schema" - j_string("S")])))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:a lacked, extra or mistyped member fails",
        ( if Refused("logical", Steps(Step(["op" - j_string("advance")]))),
             Refused("logical", Steps(Step(["op" - j_string("pump"),
                "label" - j_string("x")]))),
             Refused("logical", Steps(Step(["op" - j_string("advance"),
                "delta_ns" - j_int(-1i64)]))),
             Refused("logical", Steps(Step(["op" - j_string("assert"),
                "schema" - j_int(1i64)])))
          then yes else no ), !T, !IO),
    SeedTtl = (func(TtlJ) = Steps(Step(["op" - j_string("cache_seed"),
        "key" - j_string("k"), "value" - j_int(1i64), "ttl_ns" - TtlJ]))),
    check("RCTS.1.2.28:a cache_seed ttl_ns that is not a count fails",
        ( if Refused("logical", SeedTtl(j_int(-1i64))),
             Refused("logical", SeedTtl(j_bool(yes))),
             Refused("logical", SeedTtl(j_string("5"))),
             Refused("logical", SeedTtl(j_float(1.5)))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:a step that is not an object, and clone arrays, fail",
        ( if Refused("logical", Steps(j_string("pump"))),
             Refused("runtime", object(["after_clone"
                - j_array([Step(["op" - j_string("shake")])])]))
          then yes else no ), !T, !IO),
    Engines = "engines" - j_object(object(["a" - j_object(object([
        "rules_ds" - j_string("")]))])),
    check("RCTS.1.2.29:a cross-tier step names its engine, and may forward",
        ( if rcts_1_2_28_refusal("cross-tier", object([Engines,
                "steps" - j_array([
                    Step(["engine" - j_string("a"), "op" - j_string("pump")]),
                    Step(["engine" - j_string("a"),
                        "op" - j_string("forward"), "from" - j_string("a")]),
                    Step(["engine" - j_string("a"),
                        "op" - j_string("forward_external"),
                        "from" - j_string("a")])])])) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.29:an unknown engine or source, or a bad engines, fails",
        ( if Refused("cross-tier", object([Engines, "steps" - j_array([
                Step(["engine" - j_string("b"), "op" - j_string("pump")])])])),
             Refused("cross-tier", object([Engines, "steps" - j_array([
                Step(["op" - j_string("pump")])])])),
             Refused("cross-tier", object([Engines, "steps" - j_array([
                Step(["engine" - j_string("a"), "op" - j_string("forward"),
                    "from" - j_string("z")])])])),
             Refused("cross-tier", object(["engines" - j_object(object([]))]))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.29:engines, engine and the bridges are cross-tier's alone",
        ( if Refused("logical", object([Engines])),
             Refused("logical", Steps(Step(["engine" - j_string("a"),
                "op" - j_string("pump")]))),
             Refused("logical", Steps(Step(["op" - j_string("forward"),
                "from" - j_string("a")])))
          then yes else no ), !T, !IO),
    % `runner.py`'s `test_rcts_1_2_29__published_asserted_at_*` refuse,
    % admit and judge the same cases.
    PubAt = (func(PJ) = "expected_published_asserted_at" - PJ),
    PubAtOf = (func(PMs) = PubAt(j_object(object(PMs)))),
    check("RCTS.1.2.29:expected_published_asserted_at of its shape stands",
        ( if
            rcts_1_2_28_refusal("cross-tier", object([Engines,
                PubAtOf(["a" - j_array([j_int(0i64), j_null])])])) = no,
            rcts_1_2_28_refusal("cross-tier", object([Engines])) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.29:expected_published_asserted_at off its shape, or "
            ++ "off cross-tier, fails",
        ( if
            Refused("logical", object([PubAtOf([])])),
            Refused("cross-tier", object([Engines, PubAt(j_array([]))])),
            Refused("cross-tier", object([Engines,
                PubAtOf(["a" - j_int(5i64)])])),
            Refused("cross-tier", object([Engines,
                PubAtOf(["a" - j_array([j_bool(yes)])])])),
            Refused("cross-tier", object([Engines,
                PubAtOf(["a" - j_array([j_string("5")])])])),
            Refused("cross-tier", object([Engines,
                PubAtOf(["a" - j_array([j_float(1.5)])])])),
            Refused("cross-tier", object([Engines,
                PubAtOf(["b" - j_array([j_int(5i64)])])]))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.29:published asserted_at is read off each record",
        ( if
            GotAt = map.from_assoc_list(["a" - [yes(yes(5i64)), yes(no)]]),
            published_at_failure(["a" - [yes(5i64), no]], GotAt) = no,
            list.all_true(
                (pred(WantAt::in) is semidet :-
                    published_at_failure(["a" - WantAt], GotAt) = yes(_)),
                [[yes(5i64), yes(5i64)], [yes(5i64)],
                 [yes(5i64), no, yes(7i64)], [no, no], [yes(0i64), no]]),
            published_at_failure(["a" - [yes(5i64)]],
                map.from_assoc_list(["a" - [no]])) = yes(NoRecord),
            string.sub_string_search(NoRecord, "carried no FactExternal", _)
          then yes else no ), !T, !IO),
    % An engine's `wall_clock`: `runner.py`'s
    % `test_rcts_1_2_29__an_engine_s_wall_clock_*` admit and refuse the same.
    EngineWith = (func(WMs) = "engines" - j_object(object(["a" - j_object(
        object(["rules_ds" - j_string("") | WMs]))]))),
    check("RCTS.1.2.29:an engine may leave its wall clock unset",
        ( if
            rcts_1_2_28_refusal("cross-tier", object([EngineWith(
                ["wall_clock" - j_string("unset")])])) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.29:an engine's wall_clock is \"unset\" or absent",
        ( if
            Refused("cross-tier", object([EngineWith(
                ["wall_clock" - j_string("set")])])),
            Refused("cross-tier", object([EngineWith(
                ["wall_clock" - j_bool(yes)])])),
            Refused("cross-tier", object([EngineWith(
                ["wall_clock" - j_null])])),
            Refused("cross-tier", object([EngineWith(
                ["wall_clock" - j_string("unset"), "extra" - j_int(1i64)])]))
          then yes else no ), !T, !IO).

:- pred of_step_type(step_type::in, json::in) is semidet.

of_step_type(st_string, J) :- J = j_string(_).
of_step_type(st_object, J) :- J = j_object(_).
of_step_type(st_count, J) :- J = j_int(N), N >= 0i64.
of_step_type(st_int, J) :- J = j_int(_).
of_step_type(st_any, _).

    % [RCTS.1.2.23]'s fields, `runner.py`'s `_RECORDING_FIELDS`, less
    % `late_start`, which is `replay_refused`'s too ([RCTS.1.2.18]).
    %
:- func recording_fields = list(string).

recording_fields = ["run_id", "tier_id", "expected_event_ids",
    "expected_fact_ids", "expected_emits", "expected_publishes",
    "expected_cache_seeds", "expected_stream_kinds", "expected_slots",
    "expected_withdraw_causes", "rewrite_withdraw_cause"].

    % [RCTS.1.2.23]: why an `rfcs_roundtrip` fixture's recording fields are
    % refused, or `no`: each must be of the type the clause states.
    %
:- func rcts_1_2_23_refusal(json_members) = maybe(string).

rcts_1_2_23_refusal(Expect) = Refusal :-
    ( if
        list.find_first_match(
            (pred(F1::in) is semidet :-
                lookup_member(Expect, F1, J1),
                not J1 = j_string(_)),
            ["run_id", "tier_id"], IdField)
    then
        Refusal = yes("expect." ++ IdField
            ++ " is not a string ([RCTS.1.2.23])")
    else if
        list.find_first_match(
            (pred(F2::in) is semidet :-
                lookup_member(Expect, F2, J2),
                not string_list(J2)),
            ["expected_event_ids", "expected_stream_kinds",
             "expected_withdraw_causes"], ListField)
    then
        Refusal = yes("expect." ++ ListField
            ++ " is not an array of strings ([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "expected_slots", SlotsJ),
        not (
            SlotsJ = j_array(Slots),
            list.all_true((pred(S::in) is semidet :- S = j_object(_)), Slots)
        )
    then
        Refusal = yes("expect.expected_slots is not an array of objects "
            ++ "([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "rewrite_withdraw_cause", RewriteJ),
        not rewrite_shape(RewriteJ)
    then
        Refusal = yes("expect.rewrite_withdraw_cause is not "
            ++ "{\"index\": I, \"cause\": N} of two non-negative integers "
            ++ "([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "expected_fact_ids", FactIdsJ),
        not (
            FactIdsJ = j_array(FactIds),
            list.all_true(fact_id_entry_shape, FactIds)
        )
    then
        Refusal = yes("expect.expected_fact_ids is not an array of "
            ++ "{\"atom\": A, \"fact_id\": N}, A one of FactAssert, FactEmit "
            ++ "and FactWithdraw and N a non-negative integer ([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "expected_emits", EmitsJ),
        not (
            EmitsJ = j_array(Emits),
            list.all_true(emit_entry_shape, Emits)
        )
    then
        Refusal = yes("expect.expected_emits is not an array of "
            ++ "{\"rule_name\": R}, R a string ([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "expected_publishes", PubsJ),
        not (
            PubsJ = j_array(Pubs),
            list.all_true(publish_entry_shape, Pubs)
        )
    then
        Refusal = yes("expect.expected_publishes is not an array of "
            ++ "{\"schema_name\": S, \"rule_name\": R}, S and R strings "
            ++ "([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "expected_cache_seeds", SeedsJ),
        not (
            SeedsJ = j_array(Seeds),
            list.all_true(cache_seed_entry_shape, Seeds)
        )
    then
        Refusal = yes("expect.expected_cache_seeds is not an array of "
            ++ "{\"key\": K, \"value_json\": V, \"deadline_ns\": N}, K and V "
            ++ "strings and N an integer from 0 to 2^63 - 1 ([RCTS.1.2.23])")
    else if
        lookup_member(Expect, "late_start", LateJ),
        not (
            LateJ = j_int(Late),
            Late >= 1i64,
            Late < int64.from_int(list.length(array_member(Expect, "steps")))
        )
    then
        Refusal = yes("expect.late_start is not an integer from 1 to one less "
            ++ "than the number of steps ([RCTS.1.2.23])")
    else
        Refusal = no
    ).

    % One `expected_cache_seeds` entry ([RCTS.1.2.23]): exactly `key` and
    % `value_json`, strings, and `deadline_ns`, a non-negative integer. A JSON
    % integer here is an `int64`, so 2^63 - 1 is the largest it holds.
    %
:- pred cache_seed_entry_shape(json::in) is semidet.

cache_seed_entry_shape(J) :-
    J = j_object(Ms),
    list.sort(assoc_list.keys(members(Ms))) =
        ["deadline_ns", "key", "value_json"],
    lookup_member(Ms, "key", KeyJ),
    KeyJ = j_string(_),
    lookup_member(Ms, "value_json", ValueJ),
    ValueJ = j_string(_),
    lookup_member(Ms, "deadline_ns", DeadlineJ),
    DeadlineJ = j_int(Deadline),
    Deadline >= 0i64.

    % One `expected_emits` entry ([RCTS.1.2.23]): exactly `rule_name`, a
    % string, as `runner.py` admits it.
    %
:- pred emit_entry_shape(json::in) is semidet.

emit_entry_shape(J) :-
    J = j_object(Ms),
    assoc_list.keys(members(Ms)) = ["rule_name"],
    lookup_member(Ms, "rule_name", RuleJ),
    RuleJ = j_string(_).

    % One `expected_publishes` entry ([RCTS.1.2.23]): exactly `schema_name`
    % and `rule_name`, strings, as `runner.py` admits it.
    %
:- pred publish_entry_shape(json::in) is semidet.

publish_entry_shape(J) :-
    J = j_object(Ms),
    list.sort(assoc_list.keys(members(Ms))) = ["rule_name", "schema_name"],
    lookup_member(Ms, "schema_name", SchemaJ),
    SchemaJ = j_string(_),
    lookup_member(Ms, "rule_name", RuleJ),
    RuleJ = j_string(_).

    % One `expected_fact_ids` entry ([RCTS.1.2.23]): exactly `atom`, the name
    % of one of `fact_id_atoms`, and `fact_id`, a non-negative integer.
    %
:- pred fact_id_entry_shape(json::in) is semidet.

fact_id_entry_shape(J) :-
    J = j_object(Ms),
    list.sort(assoc_list.keys(members(Ms))) = ["atom", "fact_id"],
    lookup_member(Ms, "atom", AtomJ),
    AtomJ = j_string(Name),
    list.member(Name, list.map(atom_message, fact_id_atoms)),
    lookup_member(Ms, "fact_id", IdJ),
    IdJ = j_int(Id),
    Id >= 0i64.

    % The atoms whose `fact_id` `expected_fact_ids` reads ([RFCS.6.9]),
    % `runner.py`'s `_FACT_ID_ATOMS`. Each carries it as field 1.
    %
:- func fact_id_atoms = list(atom_id).

fact_id_atoms = [at_fact_assert, at_fact_emit, at_fact_withdraw].

:- pred string_list(json::in) is semidet.

string_list(J) :-
    J = j_array(Items),
    list.all_true((pred(I::in) is semidet :- I = j_string(_)), Items).

:- pred rewrite_shape(json::in) is semidet.

rewrite_shape(J) :-
    J = j_object(Ms),
    list.length(members(Ms)) = 2,
    lookup_member(Ms, "index", IndexJ),
    IndexJ = j_int(Index),
    Index >= 0i64,
    lookup_member(Ms, "cause", CauseJ),
    CauseJ = j_int(Cause),
    Cause >= 0i64.

    % `run_id` and `tier_id` ([RCTS.1.2.23]), given to the engine before the
    % steps run ([NLFC.1.2]): the ids every `event_id` derives from. A value
    % that is not a string is left out here and refused by
    % `rcts_1_2_23_refusal`. A JSON string is well-formed UTF-8, so each
    % setter answers `id_set`.
    %
:- func with_rfcs_ids(json_members, engine) = engine.

with_rfcs_ids(Expect, E0) = E :-
    ( if lookup_member(Expect, "run_id", RunJ), RunJ = j_string(Run) then
        set_run_id(yes(Run), _, E0, E1)
    else
        E1 = E0
    ),
    ( if lookup_member(Expect, "tier_id", TierJ), TierJ = j_string(Tier) then
        set_tier_id(yes(Tier), _, E1, E)
    else
        E = E1
    ).

    % `test_conformance.py`'s `test_rcts_1_2_23__*` cases.
    % @spec [RCTS.1.2.23]
    %
:- pred recording_fields_checks(tally::in, tally::out, io::di, io::uo) is det.

recording_fields_checks(!T, !IO) :-
    check("RCTS.1.2.23:a recording field on another kind fails",
        ( if
            list.all_true(
                (pred(F::in) is semidet :-
                    recording_fields_placed("replay_determinism",
                        object([F - j_string("x")]),
                        behave_result(bo_pass, "replay_determinism", ""))
                        ^ br_outcome = bo_fail),
                recording_fields)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:and on `rfcs_roundtrip` it stands",
        ( if recording_fields_placed("rfcs_roundtrip",
                object(["run_id" - j_string("r")]),
                behave_result(bo_pass, "rfcs_roundtrip", ""))
                ^ br_outcome = bo_pass
          then yes else no ), !T, !IO),
    Placed = (func(PKind, PPairs) = recording_fields_placed(PKind,
        object(PPairs), behave_result(bo_pass, PKind, "")) ^ br_outcome),
    check("RCTS.1.2.23:late_start is `replay_refused`'s too, and no other's",
        ( if Placed("replay_determinism", ["late_start" - j_int(1i64)])
                = bo_fail,
             Placed("rfcs_roundtrip", ["late_start" - j_int(1i64)]) = bo_pass,
             Placed("replay_refused", ["late_start" - j_int(1i64)]) = bo_pass,
             Placed("replay_refused", ["late_start" - j_int(1i64),
                "expected_cache_seeds" - j_array([])]) = bo_fail
          then yes else no ), !T, !IO),
    Refused = (pred(Pairs::in) is semidet :-
        rcts_1_2_23_refusal(object(Pairs)) = yes(_)),
    ThreeSteps = "steps" - j_array([
        j_object(object(["op" - j_string("set"), "now_ns" - j_int(0i64)])),
        j_object(object(["op" - j_string("pump")])),
        j_object(object(["op" - j_string("pump")]))]),
    check("RCTS.1.2.23:a late_start outside the steps is refused",
        ( if Refused([ThreeSteps, "late_start" - j_int(0i64)]),
             Refused([ThreeSteps, "late_start" - j_int(3i64)]),
             Refused([ThreeSteps, "late_start" - j_int(-1i64)]),
             Refused([ThreeSteps, "late_start" - j_bool(yes)]),
             Refused([ThreeSteps, "late_start" - j_float(1.0)]),
             Refused([ThreeSteps, "late_start" - j_string("1")]),
             Refused([ThreeSteps, "late_start" - j_null])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:a late_start inside the steps is admitted",
        ( if rcts_1_2_23_refusal(object([ThreeSteps,
                "late_start" - j_int(1i64)])) = no,
             rcts_1_2_23_refusal(object([ThreeSteps,
                "late_start" - j_int(2i64)])) = no
          then yes else no ), !T, !IO),
    Seed = (func(SeedMs) = j_object(object(SeedMs))),
    check("RCTS.1.2.23:an expected_cache_seeds of another shape is refused",
        ( if Refused(["expected_cache_seeds" - Seed(["key" - j_string("k"),
                "value_json" - j_string("1"), "deadline_ns" - j_int(0i64)])]),
             Refused(["expected_cache_seeds" - j_array([j_string("k")])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_string("k"), "value_json" - j_string("1")])])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_int(1i64), "value_json" - j_string("1"),
                "deadline_ns" - j_int(0i64)])])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_string("k"), "value_json" - j_int(1i64),
                "deadline_ns" - j_int(0i64)])])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_string("k"), "value_json" - j_string("1"),
                "deadline_ns" - j_int(-1i64)])])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_string("k"), "value_json" - j_string("1"),
                "deadline_ns" - j_bool(yes)])])]),
             Refused(["expected_cache_seeds" - j_array([Seed([
                "key" - j_string("k"), "value_json" - j_string("1"),
                "deadline_ns" - j_int(0i64), "ttl_ns" - j_int(0i64)])])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:an id that is not a string is refused",
        ( if Refused(["run_id" - j_int(7i64)]),
             Refused(["tier_id" - j_null])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:a list field that is not an array of strings is refused",
        ( if Refused(["expected_event_ids" - j_string("a-b")]),
             Refused(["expected_event_ids" - j_array([j_int(1i64)])]),
             Refused(["expected_stream_kinds" - j_array([j_bool(yes)])]),
             Refused(["expected_withdraw_causes" - j_string("SUPERSEDED")])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:an expected_slots entry that is not an object is refused",
        ( if Refused(["expected_slots" - j_array([j_string("Slot")])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:a rewrite_withdraw_cause of another shape is refused",
        ( if Refused(["rewrite_withdraw_cause"
                - j_object(object(["index" - j_int(0i64)]))]),
             Refused(["rewrite_withdraw_cause"
                - j_object(object(["index" - j_int(0i64),
                    "cause" - j_int(4i64), "extra" - j_int(1i64)]))]),
             Refused(["rewrite_withdraw_cause"
                - j_object(object(["index" - j_bool(yes),
                    "cause" - j_int(4i64)]))])
          then yes else no ), !T, !IO),
    FactId = (func(Atom, Id) = j_object(object(["atom" - j_string(Atom),
        "fact_id" - j_int(Id)]))),
    check("RCTS.1.2.23:an expected_fact_ids of another shape is refused",
        ( if Refused(["expected_fact_ids" - j_array([j_int(1i64)])]),
             Refused(["expected_fact_ids" - FactId("FactAssert", 1i64)]),
             Refused(["expected_fact_ids"
                - j_array([FactId("FactRetract", 1i64)])]),
             Refused(["expected_fact_ids"
                - j_array([FactId("FactAssert", -1i64)])]),
             Refused(["expected_fact_ids" - j_array([j_object(object([
                "atom" - j_string("FactAssert")]))])]),
             Refused(["expected_fact_ids" - j_array([j_object(object([
                "atom" - j_string("FactAssert"), "fact_id" - j_int(1i64),
                "seq" - j_int(0i64)]))])])
          then yes else no ), !T, !IO),
    Emit = (func(EmitMs) = j_object(object(EmitMs))),
    check("RCTS.1.2.23:an expected_emits of another shape is refused",
        ( if Refused(["expected_emits" - Emit(["rule_name" - j_string("r")])]),
             Refused(["expected_emits" - j_array([j_string("r")])]),
             Refused(["expected_emits" - j_array([Emit([])])]),
             Refused(["expected_emits" - j_array([Emit([
                "rule_name" - j_int(1i64)])])]),
             Refused(["expected_emits" - j_array([Emit([
                "rule_name" - j_string("r"), "published" - j_bool(no)])])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:an expected_publishes of another shape is refused",
        ( if Refused(["expected_publishes" - Emit([
                "schema_name" - j_string("S"), "rule_name" - j_string("r")])]),
             Refused(["expected_publishes" - j_array([j_string("S")])]),
             Refused(["expected_publishes" - j_array([Emit([
                "rule_name" - j_string("r")])])]),
             Refused(["expected_publishes" - j_array([Emit([
                "schema_name" - j_string("S")])])]),
             Refused(["expected_publishes" - j_array([Emit([
                "schema_name" - j_int(1i64), "rule_name" - j_string("r")])])]),
             Refused(["expected_publishes" - j_array([Emit([
                "schema_name" - j_string("S"), "rule_name" - j_null])])]),
             Refused(["expected_publishes" - j_array([Emit([
                "schema_name" - j_string("S"), "rule_name" - j_string("r"),
                "seq" - j_int(0i64)])])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.23:well-typed values are admitted",
        ( if rcts_1_2_23_refusal(object([
                "run_id" - j_string(""),
                "tier_id" - j_string("t"),
                "expected_event_ids" - j_array([j_string("u")]),
                "expected_stream_kinds" - j_array([j_string("fact_assert")]),
                "expected_slots" - j_array([j_object(object([]))]),
                "expected_withdraw_causes" - j_array([j_string("CAUSE_4")]),
                "rewrite_withdraw_cause" - j_object(object([
                    "index" - j_int(0i64), "cause" - j_int(4i64)])),
                "expected_fact_ids" - j_array([FactId("FactAssert", 1i64),
                    FactId("FactEmit", 2i64), FactId("FactWithdraw", 0i64)]),
                "expected_emits" - j_array([
                    Emit(["rule_name" - j_string("r")]),
                    Emit(["rule_name" - j_string("")])]),
                "expected_publishes" - j_array([
                    Emit(["schema_name" - j_string("S"),
                        "rule_name" - j_string("r")]),
                    Emit(["schema_name" - j_string(""),
                        "rule_name" - j_string("")])]),
                "expected_cache_seeds" - j_array([
                    Seed(["key" - j_string("k"), "value_json" - j_string("1"),
                        "deadline_ns" - j_int(0i64)]),
                    Seed(["key" - j_string(""), "value_json" - j_string(""),
                        "deadline_ns" - j_int(int64.max_int64)])])
             ])) = no
          then yes else no ), !T, !IO),
    RefusedStep = (func(Op, RefusedJ) = j_object(object([
        "op" - j_string(Op), "refused" - RefusedJ]))),
    StepsOf = (func(S) = object(["steps" - j_array([S])])),
    check("RCTS.1.2.27:refused on another kind fails",
        ( if rcts_1_2_27_refusal("runtime_error",
                StepsOf(RefusedStep("assert", j_string("-710")))) = yes(_),
             rcts_1_2_27_refusal("rfcs_roundtrip",
                StepsOf(RefusedStep("assert", j_string("-710")))) = no
          then yes else no ), !T, !IO),
    check("RCTS.1.2.27:refused on a step that is not an assert fails",
        ( if rcts_1_2_27_refusal("rfcs_roundtrip",
                StepsOf(RefusedStep("pump", j_string("-710")))) = yes(_)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.27:a refused that is not a string fails",
        ( if rcts_1_2_27_refusal("rfcs_roundtrip",
                StepsOf(RefusedStep("assert", j_int(-710i64)))) = yes(_)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.27:an admitted assert, or another status, fails the step",
        ( if
            rcts_1_2_27_step(RefusedStep("assert", j_string("-710")), [],
                run_ok) = run_refused(_),
            rcts_1_2_27_step(RefusedStep("assert", j_string("-710")), [],
                run_refused(refused_status(-1, "x"))) = run_refused(_)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.27:the named status lets the steps go on",
        ( if
            rcts_1_2_27_step(RefusedStep("assert", j_string("-710")), [],
                run_refused(refused_status(-710, "x"))) = run_ok,
            rcts_1_2_27_step(RefusedStep("assert", j_string("-710")),
                [eff_event(se_engine_error(
                    ee_contract_breach(cap_value_capacity), no_site))],
                run_refused(refused("x"))) = run_ok
          then yes else no ), !T, !IO).

    % `test_runner_codes.py`'s `TestTampered` and `test_conformance.py`'s
    % `test_rcts_1_2_21__*` cases.
    % @spec [RCTS.1.2.21]
    %
:- pred tamper_checks(tally::in, tally::out, io::di, io::uo) is det.

tamper_checks(!T, !IO) :-
    Bytes = [1u8, 2u8, 3u8],
    Refused = (pred(J::in) is semidet :- not tampered(J, Bytes, _)),
    % An object is judged by `structural_edit`, before the seal: only it says
    % whether the edit had a site.
    RefusedEdit = (pred(J::in) is semidet :- not structural_edit(J, Bytes, _)),
    Edit = (func(Op, Arg) = j_object(object([Op - Arg]))),
    check("RCTS.1.2.21:a string flips the named byte's lowest bit, no re-seal",
        ( if tampered(j_string("last_byte"), Bytes, [1u8, 2u8, 2u8])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:a string outside the set is refused",
        ( if Refused(j_string("first_byte")) then yes else no ), !T, !IO),
    check("RCTS.1.2.21:truncate_tail cuts the last N bytes",
        ( if structural_edit(Edit("truncate_tail", j_int(1i64)), Bytes,
                [1u8, 2u8])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:an object outside the set is refused",
        ( if RefusedEdit(Edit("cut", j_int(1i64))) then yes else no ),
        !T, !IO),
    check("RCTS.1.2.21:an object of two members is refused",
        ( if RefusedEdit(j_object(object(["truncate_tail" - j_int(1i64),
                "bad_wire_type" - j_int(257i64)])))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:an argument of another type is refused",
        ( if RefusedEdit(Edit("truncate_tail", j_string("1"))),
             RefusedEdit(Edit("drop_schema_group", j_int(1i64)))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:truncate_tail must leave bytes and cut some",
        ( if RefusedEdit(Edit("truncate_tail", j_int(0i64))),
             RefusedEdit(Edit("truncate_tail", j_int(3i64)))
          then yes else no ), !T, !IO),
    % Over a DscHeader (263) whose one field is the 32-octet hash (field 7),
    % then a Slot (257). Fails on: the wrong end kept, an empty artefact taken
    % as no site, a frame cut short, octets put after an atom rather than
    % before it, or a header the walk reaches left unsealed.
    check("RCTS.1.2.21:truncate_to keeps the first N bytes, 0 included",
        ( if
            structural_edit(Edit("truncate_to", j_int(0i64)), Bytes, []),
            structural_edit(Edit("truncate_to", j_int(2i64)), Bytes,
                [1u8, 2u8]),
            RefusedEdit(Edit("truncate_to", j_int(3i64))),
            RefusedEdit(Edit("truncate_to", j_int(-1i64)))
          then yes else no ), !T, !IO),
    Frame = (func(FN, FBody) = [0x0Au8] ++ varint_u8(list.length(FInner))
            ++ FInner :-
        FInner = tamper_delimited(FN, FBody)),
    Hdr = Frame(263, [0x3Au8, 0x20u8] ++ list.duplicate(32, 0u8)),
    Slot = Frame(257, [0x0Au8, 0x01u8, 0x54u8]),
    Art = Hdr ++ Slot,
    NoSite = (pred(NJ::in) is semidet :- not structural_edit(NJ, Art, _)),
    Insert = (func(IK, IHex) = j_object(object(["insert_bytes"
        - j_object(object(["at" - j_int(IK), "hex" - j_string(IHex)]))]))),
    check("RCTS.1.2.21:drop_atom removes one whole frame",
        ( if
            structural_edit(Edit("drop_atom", j_int(0i64)), Art, Slot),
            structural_edit(Edit("drop_atom", j_int(1i64)), Art, Hdr),
            NoSite(Edit("drop_atom", j_int(2i64))),
            NoSite(Edit("drop_atom", j_int(-1i64))),
            NoSite(Edit("drop_atom", j_string("0")))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:insert_bytes puts octets before atom K, or after "
            ++ "the last",
        ( if
            structural_edit(Insert(0i64, "0a03fa7f00"), Art,
                Frame(2047, []) ++ Art),
            structural_edit(Insert(1i64, "0a00"), Art,
                Hdr ++ [0x0Au8, 0x00u8] ++ Slot),
            structural_edit(Insert(2i64, "00ff"), Art,
                Art ++ [0x00u8, 0xFFu8])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:insert_bytes without a site, or off its shape",
        ( if
            NoSite(Insert(3i64, "00")),
            NoSite(Insert(-1i64, "00")),
            NoSite(Insert(0i64, "")),
            NoSite(Insert(0i64, "0")),
            NoSite(Insert(0i64, "0A")),
            NoSite(Insert(0i64, "zz")),
            NoSite(j_object(object(["insert_bytes"
                - j_object(object(["at" - j_int(0i64)]))]))),
            not structural_edit(Insert(2i64, "00"), Art ++ [0u8], _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:the re-seal finds the header the walk reaches, or "
            ++ "none",
        ( if
            Pre = Frame(2047, []),
            reseal(Pre ++ Art, Moved),
            Moved \= Pre ++ Art,
            sealed_hash_offset(Moved, At),
            sealed_hash_offset(Art, At0),
            At = At0 + list.length(Pre),
            reseal(Slot, Slot),
            reseal([], []),
            reseal([0x0Bu8, 0x00u8] ++ Art, [0x0Bu8, 0x00u8] ++ Art)
          then yes else no ), !T, !IO),
    Passed = (func(K) = behave_result(bo_pass, K, "")),
    check("RCTS.1.2.21:the field on another kind fails",
        ( if tamper_placed("temporal_sequence",
                object(["tamper" - Edit("truncate_tail", j_int(1i64))]),
                Passed("temporal_sequence")) ^ br_outcome = bo_fail
          then yes else no ), !T, !IO),
    % `runtime_fact_count` takes an object other than `drop_call_operand`,
    % or a list.
    FactCount = (func(FJ) = tamper_placed("runtime_fact_count",
        object(["tamper" - FJ]), Passed("runtime_fact_count")) ^ br_outcome),
    DropAtom = (func(DK) = Edit("drop_atom", j_int(DK))),
    check("RCTS.1.2.21:on `runtime_fact_count`, a structural edit stands",
        ( if
            FactCount(DropAtom(1i64)) = bo_pass,
            FactCount(j_array([DropAtom(1i64),
                Edit("truncate_tail", j_int(1i64))])) = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:and a string or drop_call_operand there fails",
        ( if
            FactCount(j_string("last_byte")) = bo_fail,
            FactCount(j_string("dsc_sha256")) = bo_fail,
            FactCount(Edit("drop_call_operand", j_string("r"))) = bo_fail
          then yes else no ), !T, !IO),
    % Fails on: the edit not made, a string or `drop_call_operand` made, or
    % `add_compiled_code` passed over when the fixture carries it (`Art` has
    % no TerminalNode, so it has no site).
    check("RCTS.1.2.21:runtime_fact_count's artefact is the edited one",
        ( if
            fact_count_edited(object(["tamper" - DropAtom(1i64)]), Art,
                Edited),
            reseal(Hdr, Edited),
            Edited \= Art,
            not fact_count_edited(object(["tamper" - j_string("last_byte")]),
                Art, _),
            not fact_count_edited(object(["tamper"
                - Edit("drop_call_operand", j_string("r"))]), Art, _),
            not fact_count_edited(object(["tamper" - DropAtom(1i64),
                "add_compiled_code" - j_object(object(["node" - j_int(1i64)]))]),
                Art, _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:and on `runtime_error` it stands",
        ( if tamper_placed("runtime_error",
                object(["tamper" - j_string("last_byte")]),
                Passed("runtime_error")) ^ br_outcome = bo_pass
          then yes else no ), !T, !IO),
    Drop = j_object(object(["drop_call_operand" - j_string("r")])),
    check("RCTS.1.2.21:on `replay_determinism`, drop_call_operand stands",
        ( if tamper_placed("replay_determinism", object(["tamper" - Drop]),
                Passed("replay_determinism")) ^ br_outcome = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:and any other tamper there fails",
        ( if
            all [J] (
                list.member(J, [j_string("last_byte"),
                    Edit("truncate_tail", j_int(1i64)),
                    j_array([Drop, Edit("truncate_tail", j_int(1i64))])])
            =>
                tamper_placed("replay_determinism", object(["tamper" - J]),
                    Passed("replay_determinism")) ^ br_outcome = bo_fail
            )
          then yes else no ), !T, !IO),
    Halt = run_refused(refused_status(-10, "engine halted")),
    check("RCTS.1.2.21:a halting last step is the run's outcome",
        ( if halting_step(Halt, yes, []) = stop(run_ok)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:a step after the halt fails the fixture",
        ( if halting_step(Halt, yes, [j_string("next")]) = stop(run_refused(_))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:a -10 with no halt latched, or another refusal, stands",
        ( if
            halting_step(Halt, no, []) = stop(Halt),
            Other = run_refused(refused_status(-1, "x")),
            halting_step(Other, yes, []) = stop(Other),
            halting_step(run_ok, no, [j_string("next")]) = next_step
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:drop_call_operand with no terminal has no site",
        ( if not call_operand_dropped(Bytes, "r", _) then yes else no ),
        !T, !IO),
    check("halted_fault names an EngineFault member, or nothing",
        ( if engine_fault_number("ARTEFACT_LIED", 1u32),
             not engine_fault_number("RECORDER", _)
          then yes else no ), !T, !IO),
    capability_edit_checks(!T, !IO),
    tamper_list_checks(!T, !IO).

    % [RCTS.1.2.21]'s list: `test_runner_codes.py`'s `TestTamperList` cases,
    % judged by `structural_edits`, before the seal.
    % @spec [RCTS.1.2.21]
    %
:- pred tamper_list_checks(tally::in, tally::out, io::di, io::uo) is det.

tamper_list_checks(!T, !IO) :-
    Atom = (func(AN, ABody) = [0x0Au8] ++ varint_u8(list.length(AInner))
            ++ AInner :-
        AInner = tamper_delimited(AN, ABody)),
    % Atom `BN` with its body's first byte given wire type 7, as
    % `bad_wire_type` leaves it.
    Broken = (func(BN, BBody) = Atom(BN, BFixed) :-
        ( if BBody = [BFirst | BRest] then
            BFixed = [(BFirst /\ 0xF8u8) \/ 0x07u8 | BRest]
        else
            BFixed = []
        )),
    Str = (func(SF, SS) = tamper_delimited(SF, utf8_bytes(SS))),
    Head = Atom(263, [0x3Au8, 0x20u8] ++ list.duplicate(32, 0u8)),
    % A schema group up to its SchemaDef: SchemaLogical (299), a Slot (257),
    % SchemaSource (302).
    Group = (func(G) = Atom(299, Str(1, G)) ++ Atom(257, [0x0Au8, 0x01u8,
        0x54u8]) ++ Atom(302, Str(1, G))),
    Def = (func(D) = Atom(256, Str(1, D))),
    Alpha = Atom(268, Str(2, "A")),
    BetaBody = t_int(1, 1) ++ t_int(2, 1),
    Art = Head ++ Group("A") ++ Def("A") ++ Group("B") ++ Def("B") ++ Alpha
        ++ Atom(269, BetaBody),
    Drop = (func(DS) = j_object(object(["drop_schema_group" - j_string(DS)]))),
    Wire = (func(WF) = j_object(object(["bad_wire_type" - j_int(WF)]))),
    % Fails on: an edit skipped.
    check("RCTS.1.2.21:a tamper list makes every edit",
        ( if
            structural_edits([Drop("A"), Wire(269i64)], Art, Both),
            Both = Head ++ Group("B") ++ Def("B") ++ Alpha
                ++ Broken(269, BetaBody)
          then yes else no ), !T, !IO),
    % Fails on: every member made to the compiled artefact. Dropped first,
    % A's group is gone and the first SchemaDef left is B's; broken first,
    % A's SchemaDef names nothing, so A has no group.
    check("RCTS.1.2.21:each edit is made to what the ones before it left",
        ( if
            structural_edits([Drop("A"), Wire(256i64)], Art, Ordered),
            Ordered = Head ++ Group("B") ++ Broken(256, Str(1, "B")) ++ Alpha
                ++ Atom(269, BetaBody),
            not structural_edits([Wire(256i64), Drop("A")], Art, _)
          then yes else no ), !T, !IO),
    % Fails on: a list of one taken for its object, a byte flip or
    % `drop_call_operand` taken inside a list, or a member with no site
    % passed over.
    check("RCTS.1.2.21:a tamper list that is no member is refused",
        ( if
            not structural_edits([], Art, _),
            not structural_edits([Drop("A")], Art, _),
            not structural_edits([j_string("last_byte"), Wire(269i64)], Art,
                _),
            not structural_edits([Drop("A"), j_string("last_byte")], Art, _),
            not structural_edits([j_array([Drop("A"), Wire(269i64)]),
                Wire(269i64)], Art, _),
            not structural_edits([j_object(object(["drop_call_operand"
                - j_string("r")])), Wire(269i64)], Art, _),
            not structural_edits([Drop("Z"), Wire(269i64)], Art, _),
            not structural_edits([Drop("A"), Wire(258i64)], Art, _)
          then yes else no ), !T, !IO).

    % [RBND.1.3]'s two tamper members and `replay_refused`'s
    % `unknown_capability`: `test_runner_codes.py`'s `TestCapabilityTampers`
    % and `TestStreamEdit` cases.
    % @spec [RCTS.1.2.21] [RCTS.1.2.18]
    %
:- pred capability_edit_checks(tally::in, tally::out, io::di, io::uo) is det.

capability_edit_checks(!T, !IO) :-
    Header = (func(HCaps) = [0x0Au8] ++ varint_u8(list.length(HInner))
            ++ HInner :-
        HInner = tamper_delimited(263,
            tamper_delimited(7, list.duplicate(32, 0u8))
            ++ tamper_delimited(13, HCaps))),
    % Fails on: the wrong entry copied, or the list re-sorted or cut.
    check("RCTS.1.2.21:duplicate_capability copies entry I into entry I + 1",
        ( if capabilities_edited("duplicate_capability", 1,
                Header([4u8, 6u8, 8u8]), Header([4u8, 6u8, 6u8]))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.21:swap_capabilities swaps entries I and I + 1",
        ( if capabilities_edited("swap_capabilities", 0,
                Header([4u8, 6u8, 8u8]), Header([6u8, 4u8, 8u8]))
          then yes else no ), !T, !IO),
    Unpacked = [0x0Au8] ++ varint_u8(list.length(UInner)) ++ UInner,
    UInner = tamper_delimited(263,
        tamper_delimited(7, list.duplicate(32, 0u8))
        ++ t_int(13, 4) ++ t_int(13, 6)),
    % Fails on: an index past the list, an edit that would move a length,
    % or a list written unpacked taken for a packed one.
    check("RCTS.1.2.21:the two capability members without a site",
        ( if
            not capabilities_edited("duplicate_capability", 1,
                Header([4u8, 6u8]), _),
            not capabilities_edited("swap_capabilities", -1,
                Header([4u8, 6u8]), _),
            not capabilities_edited("swap_capabilities", 0, Header([4u8]), _),
            not capabilities_edited("duplicate_capability", 0,
                Header([0x04u8, 0xC8u8, 0x01u8]), _),
            not capabilities_edited("duplicate_capability", 0, Unpacked, _),
            not capabilities_edited("sort_capabilities", 0,
                Header([6u8, 4u8]), _)
          then yes else no ), !T, !IO),
    Stream = (func(SBody) = [0x0Au8] ++ varint_u8(list.length(SInner))
            ++ SInner :-
        SInner = tamper_delimited(258, SBody)),
    Unknown = j_object(object(["op" - j_string("unknown_capability")])),
    % Fails on: another entry edited, or a number Capability allocates.
    check("RCTS.1.2.18:unknown_capability writes 127 into the first entry",
        ( if stream_mutated(Unknown,
                Stream(tamper_delimited(16, [4u8, 6u8])),
                Stream(tamper_delimited(16, [0x7Fu8, 6u8])))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:unknown_capability without a site",
        ( if
            not stream_mutated(Unknown, Stream(t_int(10, 1)), _),
            not stream_mutated(Unknown, Stream(t_int(16, 4)), _),
            not stream_mutated(Unknown,
                Stream(tamper_delimited(16, [0xC8u8, 0x01u8])), _),
            not stream_mutated(j_object(object(["op" - j_string(
                "unknown_capability"), "value" - j_int(9i64)])),
                Stream(tamper_delimited(16, [4u8, 6u8])), _)
          then yes else no ), !T, !IO),
    withdraw_cause_checks(!T, !IO).

    % `replay_refused`'s `withdraw_cause` and fault edits:
    % `test_runner_codes.py`'s `TestStreamEdit` cases.
    % @spec [RCTS.1.2.18]
    %
:- pred withdraw_cause_checks(tally::in, tally::out, io::di, io::uo) is det.

withdraw_cause_checks(!T, !IO) :-
    Atom = (func(ANum, ABody) = [0x0Au8] ++ varint_u8(list.length(AInner))
            ++ AInner :-
        AInner = tamper_delimited(ANum, ABody)),
    Withdraw = (func(WId, WCause) = Atom(327, t_int(1, WId) ++ t_int(2, WCause))),
    Mutation = (func(MIndex, MCause) = j_object(object([
        "op" - j_string("withdraw_cause"), "index" - j_int(MIndex),
        "cause" - j_int(MCause)]))),
    Assert = Atom(1, t_int(1, 1)),
    Two = Assert ++ Withdraw(1, 2) ++ Withdraw(2, 2),
    % Fails on: the first FactWithdraw edited whatever the index, another of
    % its fields, or a length moved.
    check("RCTS.1.2.18:withdraw_cause edits the index-th withdrawal's cause",
        ( if
            stream_mutated(Mutation(1i64, 4i64), Two,
                Assert ++ Withdraw(1, 2) ++ Withdraw(2, 4))
          then yes else no ), !T, !IO),
    One = Assert ++ Withdraw(1, 2),
    Unwritten = Assert ++ Atom(327, t_int(1, 1)),
    Wide = Assert ++ Atom(327, t_int(1, 1) ++ [0x10u8, 0x80u8, 0x01u8]),
    % Fails on: an index past the withdrawals, a cause not written, one
    % wider than one byte, the cause it already is, or an index or cause out
    % of range or of the wrong type.
    check("RCTS.1.2.18:withdraw_cause without a site",
        ( if
            not stream_mutated(Mutation(0i64, 4i64), Assert, _),
            not stream_mutated(Mutation(1i64, 4i64), One, _),
            not stream_mutated(Mutation(0i64, 4i64), Unwritten, _),
            not stream_mutated(Mutation(0i64, 4i64), Wide, _),
            not stream_mutated(Mutation(0i64, 2i64), One, _),
            not stream_mutated(Mutation(-1i64, 4i64), One, _),
            not stream_mutated(Mutation(0i64, 0i64), One, _),
            not stream_mutated(Mutation(0i64, 128i64), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"), "index" - j_bool(yes),
                "cause" - j_int(4i64)])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"), "index" - j_string("0"),
                "cause" - j_int(4i64)])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"), "index" - j_int(0i64),
                "cause" - j_bool(yes)])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"), "index" - j_int(0i64),
                "cause" - j_float(4.0)])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"),
                "index" - j_int(0i64)])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("withdraw_cause"), "index" - j_int(0i64),
                "cause" - j_int(4i64), "extra" - j_int(1i64)])), One, _)
          then yes else no ), !T, !IO),
    % `publish_name`: `test_runner_codes.py`'s `test_publish_name_*`.
    Publish = (func(PSchema, PRule, PClock) = Atom(331,
        tamper_delimited(1, utf8_bytes(PSchema))
        ++ tamper_delimited(2, utf8_bytes(PRule)) ++ t_int(3, PClock))),
    PubName = (func(PIndex, PField, PTo) = j_object(object([
        "op" - j_string("publish_name"), "index" - j_int(PIndex),
        "field" - j_string(PField), "to" - j_string(PTo)]))),
    TwoPubs = Assert ++ Publish("Pub", "r", 5) ++ Publish("Pub", "r", 6),
    % Fails on: the first FactPublish edited whatever the index, the other
    % name or another field edited, or a length moved; and code points
    % counted for octets.
    check("RCTS.1.2.18:publish_name edits the index-th publish's name alone",
        ( if
            stream_mutated(PubName(1i64, "schema_name", "Puc"), TwoPubs,
                Assert ++ Publish("Pub", "r", 5) ++ Publish("Puc", "r", 6)),
            stream_mutated(PubName(0i64, "rule_name", "s"), TwoPubs,
                Assert ++ Publish("Pub", "s", 5) ++ Publish("Pub", "r", 6)),
            stream_mutated(PubName(0i64, "rule_name", "é"),
                Assert ++ Publish("Pub", "ab", 5),
                Assert ++ Publish("Pub", "é", 5)),
            not stream_mutated(PubName(0i64, "rule_name", "rf"),
                Assert ++ Publish("Pub", "ré", 5), _)
          then yes else no ), !T, !IO),
    OnePub = Assert ++ Publish("Pub", "r", 5),
    UnwrittenPub = Assert ++ Atom(331, tamper_delimited(1, utf8_bytes("Pub"))),
    % Fails on: no index-th FactPublish, a name not written, a `to` of
    % another length or equal to what it replaces, a field that is neither
    % name, and members out of range, of the wrong type, missing or extra.
    check("RCTS.1.2.18:publish_name without a site",
        ( if
            not stream_mutated(PubName(0i64, "schema_name", "Puc"), Assert, _),
            not stream_mutated(PubName(1i64, "schema_name", "Puc"), OnePub, _),
            not stream_mutated(PubName(0i64, "rule_name", "s"),
                UnwrittenPub, _),
            not stream_mutated(PubName(0i64, "schema_name", "Pu"), OnePub, _),
            not stream_mutated(PubName(0i64, "schema_name", "Pubs"), OnePub, _),
            not stream_mutated(PubName(0i64, "schema_name", "Pub"), OnePub, _),
            not stream_mutated(PubName(0i64, "clock_ns", "Puc"), OnePub, _),
            not stream_mutated(PubName(-1i64, "schema_name", "Puc"), OnePub, _),
            not stream_mutated(j_object(object([
                "op" - j_string("publish_name"), "index" - j_bool(yes),
                "field" - j_string("schema_name"), "to" - j_string("Puc")])),
                OnePub, _),
            not stream_mutated(j_object(object([
                "op" - j_string("publish_name"), "index" - j_int(0i64),
                "field" - j_int(1i64), "to" - j_string("Puc")])), OnePub, _),
            not stream_mutated(j_object(object([
                "op" - j_string("publish_name"), "index" - j_int(0i64),
                "field" - j_string("schema_name"), "to" - j_int(5i64)])),
                OnePub, _),
            not stream_mutated(j_object(object([
                "op" - j_string("publish_name"), "index" - j_int(0i64),
                "field" - j_string("schema_name")])), OnePub, _),
            not stream_mutated(j_object(object([
                "op" - j_string("publish_name"), "index" - j_int(0i64),
                "field" - j_string("schema_name"), "to" - j_string("Puc"),
                "extra" - j_int(1i64)])), OnePub, _)
          then yes else no ), !T, !IO),
    Fault = (func(FOp, FAtomName) = j_object(object([
        "atom" - j_string(FAtomName), "op" - j_string(FOp)]))),
    Type = (func(TNode) = Atom(328, t_int(1, TNode) ++ t_int(6, 9))),
    Comp = (func(CNode) = Atom(325, t_int(7, CNode))),
    check("RCTS.1.2.18:fault_node raises the first fault's node_id alone",
        ( if
            stream_mutated(Fault("fault_node", "TypeError"),
                Assert ++ Type(5) ++ Type(6), Assert ++ Type(6) ++ Type(6))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:fault_node without a site",
        ( if
            not stream_mutated(Fault("fault_node", "TypeError"), Assert, _),
            not stream_mutated(Fault("fault_node", "TypeError"),
                Assert ++ Type(127), _),
            not stream_mutated(Fault("fault_node", "TypeError"),
                Assert ++ Atom(328, [0x08u8, 0x80u8, 0x01u8]), _),
            not stream_mutated(Fault("fault_node", "ComputationError"),
                Assert ++ Atom(325, t_int(6, 1)), _),
            not stream_mutated(Fault("fault_node", "EngineError"),
                Assert ++ Type(5), _)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:drop_fault removes the first fault's frame alone",
        ( if
            stream_mutated(Fault("drop_fault", "ComputationError"),
                Assert ++ Comp(1) ++ Comp(2), Assert ++ Comp(2))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:drop_fault without a site",
        ( if
            not stream_mutated(Fault("drop_fault", "ComputationError"), Assert, _),
            not stream_mutated(Fault("drop_fault", "TypeError"),
                Assert ++ Comp(1), _),
            not stream_mutated(Fault("drop_fault", "ComputationError"),
                Assert ++ Comp(1) ++ [0xFFu8], _)
          then yes else no ), !T, !IO),
    AppendOp = j_object(object(["op" - j_string("append_engine_error")])),
    EngineAtom = Atom(330, t_int(1, 1) ++ t_int(4, 999)
        ++ tamper_delimited(5, [0x72u8])),
    check("RCTS.1.2.18:append_engine_error adds one frame after the rest",
        ( if stream_mutated(AppendOp, Assert, Assert ++ EngineAtom)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.18:append_engine_error without a site",
        ( if
            not stream_mutated(AppendOp, Assert ++ EngineAtom, _),
            not stream_mutated(AppendOp, Assert ++ [0xFFu8], _),
            not stream_mutated(AppendOp, [], _)
          then yes else no ), !T, !IO),
    seed_after_event_checks(!T, !IO).

    % `replay_refused`'s `seed_after_event` and `replay_cache_cap`:
    % `test_runner_codes.py`'s `TestStreamEdit` and `TestLateStart` cases.
    % @spec [RCTS.1.2.18]
    %
:- pred seed_after_event_checks(tally::in, tally::out, io::di, io::uo) is det.

seed_after_event_checks(!T, !IO) :-
    Atom = (func(ANum, ABody) = [0x0Au8] ++ varint_u8(list.length(AInner))
            ++ AInner :-
        AInner = tamper_delimited(ANum, ABody)),
    Header = Atom(258, tamper_delimited(10, [0x30u8])),
    SchemaDef = Atom(256, tamper_delimited(1, [0x54u8])),
    Slot = Atom(257, tamper_delimited(1, [0x54u8])),
    SeedA = Atom(6, tamper_delimited(1, [0x61u8])),
    SeedB = Atom(6, tamper_delimited(1, [0x62u8])),
    Clock = Atom(3, t_int(1, 5)),
    Fact = Atom(1, t_int(1, 1)),
    Move = j_object(object(["op" - j_string("seed_after_event")])),
    % Fails on: the seed moved past a SchemaDef, a Slot or another CacheSeed,
    % which is still the prelude; the second seed moved instead of the first;
    % or a frame's bytes changed rather than its place.
    check("RCTS.1.2.18:seed_after_event moves the first seed past the first "
            ++ "event",
        ( if stream_mutated(Move,
                Header ++ SchemaDef ++ Slot ++ SeedA ++ SeedB ++ Clock ++ Fact,
                Header ++ SchemaDef ++ Slot ++ SeedB ++ Clock ++ SeedA ++ Fact)
          then yes else no ), !T, !IO),
    % Fails on: a recording with no seed, or no event after it, replayed
    % unaltered; or a member the op does not take.
    check("RCTS.1.2.18:seed_after_event without a site",
        ( if
            not stream_mutated(Move, Header ++ Clock, _),
            not stream_mutated(Move, Header ++ SeedA, _),
            not stream_mutated(j_object(object([
                "op" - j_string("seed_after_event"), "index" - j_int(0i64)])),
                Header ++ SeedA ++ Clock, _)
          then yes else no ), !T, !IO),
    Note = (func(NTag) = Atom(261, tamper_delimited(2, [0x72u8])
        ++ t_int(6, NTag))),
    Call = (func(CTag) = Atom(262, tamper_delimited(1, [0x73u8])
        ++ t_int(8, CTag))),
    Split = (func(SAtom) = j_object(object(["op" - j_string("split_timetag"),
        "atom" - SAtom]))),
    % Fails on: a value another atom carries (1 and 2 are taken),
    % the firing's annotations edited, the wrong call edited, or a value that
    % narrows the varint and so moves a length.
    check("RCTS.1.2.18:split_timetag gives the call the least free value",
        ( if
            stream_mutated(Split(j_int(1i64)),
                Note(5) ++ Call(5) ++ Call(5) ++ Note(5) ++ Note(1)
                    ++ Atom(329, t_int(5, 2)),
                Note(5) ++ Call(5) ++ Call(3) ++ Note(5) ++ Note(1)
                    ++ Atom(329, t_int(5, 2))),
            stream_mutated(Split(j_int(0i64)),
                Note(200) ++ Call(200) ++ Note(200),
                Note(200) ++ Call(128) ++ Note(200))
          then yes else no ), !T, !IO),
    One = Note(5) ++ Call(5) ++ Note(5),
    Full = list.condense(list.map(Note, 1 .. 127)) ++ Call(5),
    % Fails on: an index past the calls, a timetag not written, a width with
    % no free value, and an `atom` of the wrong type or a member too many.
    check("RCTS.1.2.18:split_timetag without a site",
        ( if
            not stream_mutated(Split(j_int(0i64)), Note(5), _),
            not stream_mutated(Split(j_int(1i64)), One, _),
            not stream_mutated(Split(j_int(0i64)),
                Note(5) ++ Atom(262, tamper_delimited(1, [0x73u8]))
                    ++ Note(5), _),
            not stream_mutated(Split(j_int(0i64)), Full, _),
            not stream_mutated(Split(j_int(-1i64)), One, _),
            not stream_mutated(Split(j_bool(yes)), One, _),
            not stream_mutated(Split(j_string("0")), One, _),
            not stream_mutated(Split(j_float(0.0)), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("split_timetag")])), One, _),
            not stream_mutated(j_object(object([
                "op" - j_string("split_timetag"), "atom" - j_int(0i64),
                "extra" - j_int(1i64)])), One, _)
          then yes else no ), !T, !IO),
    Steps = "steps" - j_array(list.duplicate(3,
        j_object(object(["op" - j_string("pump")])))),
    Mutation = "mutation" - j_object(object(["op" -
        j_string("retract_unknown_fact_id")])),
    Cap = (func(CapMs) = "replay_cache_cap" - j_object(object(CapMs))),
    % Fails on: a cap beside another alteration, so the refusal could be
    % either's, or one of another shape, which bounds nothing.
    check("RCTS.1.2.18:a replay_cache_cap alone is the alteration",
        ( if
            late_start_field(object([Steps, Cap(["keys" - j_int(1i64)])]))
                = reader_cache_cap,
            late_start_field(object([Steps, Cap(["bytes" - j_int(8i64)])]))
                = reader_cache_cap,
            late_start_field(object([Steps, Cap([])])) = reader_cache_cap,
            late_start_field(object([Steps, Mutation])) = no_late_start,
            late_start_field(object([Steps, Mutation,
                Cap(["keys" - j_int(1i64)])])) = late_malformed(_),
            late_start_field(object([Steps, "late_start" - j_int(1i64),
                Cap(["keys" - j_int(1i64)])])) = late_malformed(_),
            late_start_field(object([Steps])) = late_malformed(_),
            late_start_field(object([Steps, Cap(["keys" - j_int(-1i64)])]))
                = late_malformed(_),
            late_start_field(object([Steps, Cap(["keys" - j_bool(yes)])]))
                = late_malformed(_),
            late_start_field(object([Steps, Cap(["entries" - j_int(1i64)])]))
                = late_malformed(_),
            late_start_field(object([Steps,
                "replay_cache_cap" - j_int(1i64)])) = late_malformed(_)
          then yes else no ), !T, !IO),
    Placed = (func(PKind) = replay_cache_cap_placed(PKind,
        object([Cap(["keys" - j_int(1i64)])]),
        behave_result(bo_pass, PKind, "")) ^ br_outcome),
    check("RCTS.1.2.18:replay_cache_cap is replay_refused's alone",
        ( if
            Placed("replay_determinism") = bo_fail,
            Placed("rfcs_roundtrip") = bo_fail,
            Placed("runtime_error") = bo_fail,
            Placed("replay_refused") = bo_pass
          then yes else no ), !T, !IO).

    % `test_conformance.py`'s `test_rcts_1_2_25__*`, `test_rcts_1_2_26__*`,
    % `test_rcts_1_2_30__*` and `test_rcts_1_2_31__*` cases.
    % @spec [RCTS.1.2.25]
    % @spec [RCTS.1.2.26]
    % @spec [RCTS.1.2.30]
    % @spec [RCTS.1.2.31]
    % @spec [RCTS.1.2.32]
    % @spec [RCTS.1.2.33]
    %
:- pred kind_fields_checks(tally::in, tally::out, io::di, io::uo) is det.

kind_fields_checks(!T, !IO) :-
    Passed = (func(PassK) = behave_result(bo_pass, PassK, "")),
    Placed = (func(PK, PMs) = kind_fields_placed(PK, object(PMs), Passed(PK))
        ^ br_outcome),
    check("RCTS.1.2.25:each runtime_error field on another kind fails",
        ( if
            list.all_true(
                (pred(EF::in) is semidet :-
                    Placed("runtime_fact_count",
                        [EF - j_int(0i64)]) = bo_fail),
                runtime_error_fields)
          then yes else no ), !T, !IO),
    Code = "code" - j_string("-710"),
    check("RCTS.1.2.25:and on `runtime_error` it stands",
        ( if
            Placed("runtime_error",
                [Code, "halted_fault" - j_string("ARTEFACT_LIED")]) = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:code, message_contains and cache_seeds are shared",
        ( if
            Placed("runtime_fact_count", [Code,
                "message_contains" - j_string("x"),
                "cache_seeds" - j_array([]),
                "fact_count_after" - j_int(0i64)]) = bo_pass
          then yes else no ), !T, !IO),
    Count = "fact_count_after" - j_int(1i64),
    Sch = j_string("T"),
    Gen = (func(GMs) = "generate_asserts" - j_array([j_object(object(GMs))])),
    check("RCTS.1.2.31:a fixture of either kind with no count fails",
        ( if
            Placed("runtime_fact_count", []) = bo_fail,
            Placed("temporal_sequence", ["steps" - j_array([])]) = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.31:a value of another type is refused",
        ( if
            list.all_true(
                (pred(BadMs::in) is semidet :-
                    Placed("runtime_fact_count", BadMs) = bo_fail),
                [["fact_count_after" - j_int(-1i64)],
                 ["fact_count_after" - j_float(1.0)],
                 ["fact_count_after" - j_string("1")],
                 ["fact_count_after" - j_bool(yes)],
                 [Count, "asserts" - Sch],
                 [Count, "asserts" - j_array([j_int(1i64)])],
                 [Count, "asserts" - j_array([j_object(object([]))])],
                 [Count, "asserts" - j_array([j_object(object(
                    ["schema" - j_int(1i64)]))])],
                 [Count, "asserts" - j_array([j_object(object(
                    ["schema" - Sch, "slots" - j_array([])]))])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_string("v")])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_string("v"),
                    "count" - j_int(-1i64)])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_string("v"),
                    "count" - j_string("3")])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_int(1i64),
                    "count" - j_int(3i64)])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_string("v"),
                    "count" - j_int(3i64), "start" - j_string("1")])],
                 [Count, Gen(["schema" - Sch, "slot_name" - j_string("v"),
                    "count" - j_int(3i64), "start" - j_float(1.5)])],
                 [Count, "pump" - j_string("yes")],
                 [Count, "pump" - j_int(1i64)],
                 [Count, "cache_seeds" - j_array([j_object(object(
                    ["key" - j_string("k")]))])],
                 [Count, "add_compiled_code" - j_int(3i64)],
                 [Count, "add_compiled_code" - j_object(object([]))],
                 [Count, "add_compiled_code" - j_object(object(
                    ["node" - j_int(0i64)]))],
                 [Count, "add_compiled_code" - j_object(object(
                    ["node" - j_string("3")]))],
                 [Count, "add_compiled_code" - j_object(object(
                    ["node" - j_bool(yes)]))],
                 [Count, "add_compiled_code" - j_object(object(
                    ["node" - j_int(3i64), "arch" - j_string("amd64")]))]])
          then yes else no ), !T, !IO),
    AddCode = "add_compiled_code" - j_object(object(["node" - j_int(3i64)])),
    check("RCTS.1.2.31:add_compiled_code on another kind fails",
        ( if
            Placed("temporal_sequence", ["fact_count_after" - j_int(0i64),
                "steps" - j_array([]), AddCode]) = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.31:and on `runtime_fact_count` it stands",
        ( if Placed("runtime_fact_count", [Count, AddCode]) = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.31:well-typed values are admitted",
        ( if
            Placed("runtime_fact_count", [Count,
                "cache_seeds" - j_array([j_object(object(
                    ["key" - j_string("k"), "value" - j_int(1i64)]))]),
                "asserts" - j_array([j_object(object(["schema" - Sch])),
                    j_object(object(["schema" - Sch,
                        "slots" - j_object(object(["v" - j_int(1i64)]))]))]),
                Gen(["schema" - Sch, "slot_name" - j_string("v"),
                    "count" - j_int(0i64), "start" - j_int(-2i64)]),
                "pump" - j_bool(no)]) = bo_pass,
            Placed("temporal_sequence", ["fact_count_after" - j_int(0i64),
                "steps" - j_array([j_object(object(["op" - j_string("pump")]))])])
                = bo_pass,
            % The four inputs are `runtime_fact_count`'s; nothing reads them
            % on `temporal_sequence`.
            Placed("temporal_sequence", [Count, "pump" - j_string("yes")])
                = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.32:each event-list kind's array is required and strings",
        ( if
            list.all_true(
                (pred(LK::in) is semidet :-
                    event_list_field(LK, LF),
                    Placed(LK, []) = bo_fail,
                    Placed(LK, [LF - j_null]) = bo_fail,
                    Placed(LK, [LF - j_string("a")]) = bo_fail,
                    Placed(LK, [LF - j_array([j_string("a"), j_int(1i64)])])
                        = bo_fail,
                    Placed(LK, [LF - j_array([j_array([j_string("a")])])])
                        = bo_fail,
                    Placed(LK, [LF - j_array([])]) = bo_pass,
                    Placed(LK, [LF - j_array([j_string("a"), j_string("b")])])
                        = bo_pass),
                ["rule_fire_order", "log_message_sequence", "event_sequence",
                 "event_sequence_strict", "event_kinds_forbidden"])
          then yes else no ), !T, !IO),
    Unset = "wall_clock" - j_string("unset"),
    check("RCTS.1.2.32:wall_clock is \"unset\" on a logical kind alone",
        ( if
            Placed("log_message_sequence",
                ["expected_messages" - j_array([]), Unset]) = bo_pass,
            Placed("introspection_assert", ["checks" - j_array([j_object(
                object(["surface" - j_string("fact_count"),
                    "equals" - j_int(0i64)]))]), Unset]) = bo_pass,
            list.all_true(
                (pred(NK::in) is semidet :- Placed(NK, [Count, Unset]) = bo_fail),
                ["temporal_sequence", "runtime_fact_count", "adapter_calls"]),
            list.all_true(
                (pred(WJ::in) is semidet :-
                    Placed("rule_fire_order", ["expected_rule_names"
                        - j_array([]), "wall_clock" - WJ]) = bo_fail),
                [j_string("set"), j_string(""), j_null, j_bool(no),
                 j_int(0i64)])
          then yes else no ), !T, !IO),
    Mono = "event_seq_monotonic",
    check("RCTS.1.2.33:an event_seq_monotonic value of another type is refused",
        ( if
            list.all_true(
                (pred(MP::in) is semidet :- Placed(Mono, [MP]) = bo_fail),
                ["filter_kind" - j_int(1i64), "min_events" - j_int(-1i64),
                 "min_events" - j_string("3"), "min_events" - j_bool(yes),
                 "expected_seq_step" - j_int(0i64),
                 "expected_seq_step" - j_float(1.0),
                 "expected_clocks" - j_int(5i64),
                 "expected_clocks" - j_array([j_int(5i64), j_string("6")]),
                 "expected_clocks" - j_array([j_int(-1i64)])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.33:event_seq_monotonic well typed is admitted",
        ( if
            Placed(Mono, []) = bo_pass,
            Placed(Mono, ["filter_kind" - j_string("fact_assert"),
                "min_events" - j_int(0i64), "expected_seq_step" - j_int(1i64),
                "expected_clocks" - j_array([j_int(0i64),
                    j_int(5000000000i64)])]) = bo_pass
          then yes else no ), !T, !IO),
    Hdr = (func(HMs) = j_object(object(HMs))),
    Checks = (func(CJs) = "checks" - j_array(CJs)),
    check("RCTS.1.2.33:a malformed header check is refused",
        ( if
            Placed("header_field_eq", []) = bo_fail,
            list.all_true(
                (pred(CJs::in) is semidet :-
                    Placed("header_field_eq", [Checks(CJs)]) = bo_fail),
                [[], [j_int(1i64)],
                 [Hdr(["field" - j_string("session_id")])],
                 [Hdr(["field" - j_string("capabilities"),
                    "present" - j_bool(yes)])],
                 [Hdr(["field" - j_string("dialect_def_sha256"),
                    "present" - j_bool(yes)])],
                 [Hdr(["field" - j_string("session_id"),
                    "equals" - j_string(""), "present" - j_bool(no)])],
                 [Hdr(["field" - j_string("session_id"),
                    "equals" - j_int(2i64)])],
                 [Hdr(["field" - j_string("dsc_hash"),
                    "equals" - j_string("")])],
                 [Hdr(["field" - j_string("dsc_hash"),
                    "present" - j_int(1i64)])],
                 [Hdr(["field" - j_string("session_id"),
                    "byte_len" - j_int(0i64)])],
                 [Hdr(["field" - j_string("dsc_hash"),
                    "byte_len" - j_int(-1i64)])],
                 [Hdr(["field" - j_string("dsc_hash"),
                    "length" - j_int(32i64)])]])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.33:well-formed header checks are admitted",
        ( if
            Placed("header_field_eq", [Checks([
                Hdr(["field" - j_string("session_id"), "equals" - j_string("")]),
                Hdr(["field" - j_string("ds_version"), "present" - j_bool(yes)]),
                Hdr(["field" - j_string("tier_id"), "equals" - j_string("edge")]),
                Hdr(["field" - j_string("dsc_hash"), "present" - j_bool(yes)]),
                Hdr(["field" - j_string("dsc_hash"), "byte_len" - j_int(32i64)])
            ])]) = bo_pass
          then yes else no ), !T, !IO),
    Refused = (pred(RMs::in) is semidet :-
        rcts_1_2_25_refusal(object(RMs)) = RWhy,
        string.sub_string_search(RWhy, "RCTS.1.2.25", _)),
    check("RCTS.1.2.25:a fixture with no code, or a code of another form, "
            ++ "is refused",
        ( if
            Refused([]),
            Refused(["code" - j_int(-710i64)]),
            Refused(["code" - j_string("710")]),
            Refused(["code" - j_string("-0")]),
            Refused(["code" - j_string("-7a")])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:steps with asserts or pump is refused",
        ( if
            Refused([Code, "steps" - j_array([]), "asserts" - j_array([])]),
            Refused([Code, "steps" - j_array([]), "pump" - j_bool(yes)])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:a value of another type is refused",
        ( if
            Refused([Code, "message_contains" - j_int(1i64)]),
            % An array holds strings, at least one.
            Refused([Code, "message_contains" - j_array([])]),
            Refused([Code, "message_contains" - j_array([j_string("a"),
                j_int(1i64)])]),
            Refused([Code, "asserts" - j_array([j_int(1i64)])]),
            Refused([Code, "pump" - j_string("yes")]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k")]))])]),
            % `text` is a string, and it is that or `value`.
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text" - j_int(1i64)]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text" - j_string("1"),
                 "value" - j_int(1i64)]))])]),
            % `text_bytes` is two hex digits per octet, never beside `text`
            % ([LSTR.8.5]).
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("c0 af")]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("c")]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("zz")]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_int(5i64)]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("22"),
                 "text" - j_string("1")]))])]),
            % ... and holds no `00` octet ([LSTR.1.5]).
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("00")]))])]),
            Refused([Code, "cache_seeds" - j_array([j_object(object(
                ["key" - j_string("k"), "text_bytes" - j_string("c000")]))])]),
            Refused([Code, "cache_cap" - j_object(object(
                ["rows" - j_int(1i64)]))]),
            Refused([Code, "cache_cap" - j_object(object(
                ["keys" - j_int(-1i64)]))]),
            Refused([Code, "fault_at" - j_bool(yes)]),
            Refused([Code, "fact_count_after" - j_int(-1i64)]),
            Refused([Code, "no_fault_events" - j_int(1i64)]),
            Refused([Code, "fault_events" - j_array([j_string("bounds")])]),
            Refused([Code, "halted_fault" - j_int(1i64)]),
            Refused([Code, "last_event" - j_string("rule_fire_begin")]),
            Refused([Code, "last_event" - j_int(1i64)])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:halted_fault with fact_count_after is refused",
        ( if
            Refused([Code, "halted_fault" - j_string("ARTEFACT_LIED"),
                "fact_count_after" - j_int(0i64)])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:well-typed values are admitted",
        ( if
            not rcts_1_2_25_refusal(object([Code,
                "message_contains" - j_string("capacity"),
                "steps" - j_array([j_object(object(["op" - j_string("pump")]))]),
                "cache_seeds" - j_array([j_object(object(
                    ["key" - j_string("k"), "value" - j_int(1i64)])),
                    j_object(object(["key" - j_string("j"),
                        "text" - j_string("9223372036854775808")])),
                    j_object(object(["key" - j_string("b"),
                        "text_bytes" - j_string("22EDa08022")])),
                    j_object(object(["key" - j_string("c"),
                        "text_bytes" - j_string("c0af")])),
                    j_object(object(["key" - j_string("d"),
                        "text_bytes" - j_string("a00b")]))]),
                "cache_cap" - j_object(object(["keys" - j_int(1i64),
                    "bytes" - j_int(0i64)])),
                "fault_at" - j_int(0i64),
                "no_fault_events" - j_bool(no),
                "fault_events" - j_array([j_string("bounds_error"),
                    j_string("engine_error")]),
                "fact_count_after" - j_int(0i64),
                "last_event" - j_string("bounds_error")])) = _,
            not rcts_1_2_25_refusal(object([Code,
                "halted_fault" - j_string("ARTEFACT_LIED"),
                "last_event" - j_string("engine_error")])) = _,
            not rcts_1_2_25_refusal(object([Code,
                "message_contains" - j_array([j_string("Slot"),
                    j_string(" at offset ")])])) = _
          then yes else no ), !T, !IO),
    check("RCTS.1.2.25:message_contains asks for every string it holds",
        ( if
            Wants = message_wants(object(["message_contains"
                - j_array([j_string("Slot"), j_string(" at offset ")])])),
            Wants = ["Slot", " at offset "],
            contains_all("dsc: Slot body failed at offset 7", Wants),
            not contains_all("dsc: Slot body failed", Wants),
            not contains_all("at offset 7", Wants),
            message_wants(object(["message_contains" - j_string("x")])) = ["x"],
            message_wants(object([])) = []
          then yes else no ), !T, !IO),
    % A seed's `text` reaches the runtime as written, a `value` as
    % `python_json_dumps` writes it, and an integer literal outside int64 is
    % refused as libds refuses it: DS_ERR_PARSE, with libds's text.
    check("RCTS.1.2.25:a seed's text is handed over as written, and an "
            ++ "integer outside int64 is refused as -100",
        ( if
            seed_step_text(object(["key" - j_string("k"),
                "text" - j_string("9223372036854775808")]),
                yes("9223372036854775808")),
            seed_step_text(object(["key" - j_string("k"),
                "value" - j_int(1i64)]), yes("1")),
            % [LSTR.8.5]: `text_bytes` reaches the runtime as its octets.
            seed_step_text(object(["key" - j_string("k"),
                "text_bytes" - j_string("2261")]), yes("\"a")),
            not seed_step_text(object(["key" - j_string("k")]), _),
            seed_status(seed_text_refused(ds.json_text.jr_int_outside_int64)) =
                run_refused(refused_status(-100, Msg)),
            string.sub_string_search(Msg,
                "JSON integer literal outside int64", _)
          then yes else no ), !T, !IO),
    % [LGRA.5.8.10]: a float literal that rounds to an infinity is
    % DS_ERR_PARSE too, with libds's text for it and not the integer's.
    check("RCTS.1.2.25:a float literal past the double range is refused as "
            ++ "-100, in libds's words",
        ( if
            seed_status(seed_text_refused(
                ds.json_text.jr_float_outside_double)) =
                run_refused(refused_status(-100, FMsg)),
            FMsg = "JSON float literal outside the double range"
          then yes else no ), !T, !IO),
    OnePump = "steps" - j_array([
        j_object(object(["op" - j_string("assert"), "schema" - j_string("T")])),
        j_object(object(["op" - j_string("pump")]))]),
    Statuses = (func(SJs) = "expected_pump_statuses" - SJs),
    check("RCTS.1.2.30:expected_pump_statuses on another kind fails",
        ( if
            list.all_true(
                (pred(OK::in) is semidet :-
                    Placed(OK, [OnePump, Statuses(j_array([j_int(0i64)]))])
                        = bo_fail),
                ["adapter_cache_sets", "adapter_mock", "runtime_error",
                 "event_sequence"])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:and on `adapter_calls` it stands",
        ( if
            Placed("adapter_calls",
                [OnePump, Statuses(j_array([j_int(-216i64)]))]) = bo_pass,
            Placed("adapter_calls", [OnePump]) = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:on `replay_determinism` it stands, but not beside `tamper`",
        ( if
            Placed("replay_determinism",
                [OnePump, Statuses(j_array([j_int(-216i64)]))]) = bo_pass,
            Placed("replay_determinism",
                [OnePump, Statuses(j_array([j_int(0i64)])),
                 "tamper" - j_object(object(
                    ["drop_call_operand" - j_string("r")]))]) = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:a value of another type is refused",
        ( if
            list.all_true(
                (pred(BadJ::in) is semidet :-
                    Placed("adapter_calls", [OnePump, Statuses(BadJ)])
                        = bo_fail),
                [j_string("0"), j_int(0i64), j_null,
                 j_array([j_string("-216")]), j_array([j_bool(yes)]),
                 j_array([j_int(1i64)]), j_array([j_float(-216.0)])])
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:one entry for each pump step",
        ( if
            Placed("adapter_calls", [OnePump, Statuses(j_array([]))])
                = bo_fail,
            Placed("adapter_calls", [OnePump,
                Statuses(j_array([j_int(0i64), j_int(0i64)]))]) = bo_fail
          then yes else no ), !T, !IO),
    Judged = (func(JMs, JGot) = pump_statuses_result("adapter_calls",
        object(JMs), JGot, Passed("adapter_calls")) ^ br_outcome),
    TwoStatuses = Statuses(j_array([j_int(-216i64), j_int(0i64)])),
    check("RCTS.1.2.30:the pumps' statuses must be the array",
        ( if
            Judged([TwoStatuses], [-216, 0]) = bo_pass,
            Judged([TwoStatuses], [0, 0]) = bo_fail,
            Judged([TwoStatuses], [-216, -216]) = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.28:without the field, a pump that reports a status fails",
        ( if
            Judged([], [-216]) = bo_fail,
            Judged([], [0, 0]) = bo_pass
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:on a cross-tier kind it stands, one entry per pump",
        ( if
            Placed("cross_tier_fact_counts",
                [OnePump, Statuses(j_array([j_int(-710i64)]))]) = bo_pass,
            Placed("cross_tier_per_engine_event_counts",
                [OnePump, Statuses(j_array([j_int(0i64)]))]) = bo_pass,
            Placed("cross_tier_fact_counts",
                [OnePump, Statuses(j_array([]))]) = bo_fail
          then yes else no ), !T, !IO),
    check("RCTS.1.2.30:a pump's status is its first eff_pump_status, as libds's",
        ( if
            pump_status_code([]) = 0,
            pump_status_code([eff_pump_status(ps_nan_rejected),
                eff_pump_status(ps_contract_breach(cap_cache))]) = -216
          then yes else no ), !T, !IO),
    Ref = "add_schema_ref" - j_object(object(["schema" - j_string("S"),
        "slot" - j_string("n"), "ref" - j_string("S")])),
    FactCount = j_object(object(["surface" - j_string("fact_count"),
        "equals" - j_int(1i64)])),
    check("RCTS.1.2.26:add_schema_ref on another kind fails",
        ( if Placed("event_sequence", [Ref]) = bo_fail then yes else no ),
        !T, !IO),
    check("RCTS.1.2.26:and on `introspection_assert` it stands",
        ( if
            Placed("introspection_assert",
                [Ref, "checks" - j_array([FactCount])]) = bo_pass
          then yes else no ), !T, !IO),
    Check = (func(CMs) = j_object(object(CMs))),
    Malformed = (pred(MChecks::in) is semidet :-
        rcts_1_2_26_refusal(object(["checks" - MChecks])) = MWhy,
        string.sub_string_search(MWhy, "RCTS.1.2.26", _)),
    check("RCTS.1.2.26:no checks, or none, is refused",
        ( if
            rcts_1_2_26_refusal(object([])) = _,
            Malformed(j_array([])),
            Malformed(FactCount)
          then yes else no ), !T, !IO),
    check("RCTS.1.2.26:a check missing a member its surface takes is refused",
        ( if
            Malformed(j_array([Check(["surface" - j_string("fact_count")])])),
            Malformed(j_array([Check(["surface" - j_string("rete_network"),
                "min_nodes" - j_int(1i64)])])),
            Malformed(j_array([Check(["surface" - j_string("slot_schema_ref"),
                "schema" - j_string("S"), "slot" - j_string("n")])]))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.26:a surface outside the set, an extra member, or a "
            ++ "value of another type is refused",
        ( if
            Malformed(j_array([Check(["surface" - j_string("agenda")])])),
            Malformed(j_array([Check(["surface" - j_string("fact_count"),
                "equals" - j_int(1i64), "min" - j_int(0i64)])])),
            Malformed(j_array([Check(["surface" - j_string("justifiers"),
                "fact_id" - j_int(0i64), "expect_rules" - j_array([])])])),
            Malformed(j_array([Check(["surface" - j_string("slot_schema_ref"),
                "schema" - j_string("S"), "slot" - j_string("n"),
                "equals" - j_int(1i64)])]))
          then yes else no ), !T, !IO),
    check("RCTS.1.2.26:an add_schema_ref of another shape is refused",
        ( if
            rcts_1_2_26_refusal(object(["checks" - j_array([FactCount]),
                "add_schema_ref" - j_object(object(["schema" - j_string("S"),
                    "slot" - j_string("n")]))])) = _
          then yes else no ), !T, !IO),
    check("RCTS.1.2.26:every surface's well-formed check is admitted",
        ( if
            not rcts_1_2_26_refusal(object([Ref, "checks" - j_array([
                FactCount,
                Check(["surface" - j_string("justifiers"),
                    "fact_id" - j_int(1i64),
                    "expect_rules" - j_array([j_string("r")])]),
                Check(["surface" - j_string("justifier_count"),
                    "fact_id" - j_int(1i64), "count" - j_int(0i64)]),
                Check(["surface" - j_string("rete_network"),
                    "min_nodes" - j_int(0i64), "min_edges" - j_int(0i64)]),
                Check(["surface" - j_string("slot_schema_ref"),
                    "schema" - j_string("S"), "slot" - j_string("n"),
                    "equals" - j_null])])])) = _
          then yes else no ), !T, !IO).

    % `rewrite_withdraw_cause` ([RFCS.7a.2]): `{"index": I, "cause": N}`
    % writes the run's I-th withdrawal, in stream order, with cause N, as
    % `se_fact_withdraw_unnamed(Id, N)` before `ds.rfcs` encodes. It is how a
    % vector puts a cause the enum does not name in a recording. A fixture
    % naming a withdrawal the run does not have fails.
    %
:- type rewrite
    --->    rewrite_none
    ;       rewrite_done(list({seq, stream_event}))
    ;       rewrite_missing(string).

:- func rewrite_withdraw_cause(json_members, list({seq, stream_event}))
    = rewrite.

rewrite_withdraw_cause(Expect, Records) = Rewrite :-
    ( if lookup_member(Expect, "rewrite_withdraw_cause", RJ) then
        ( if
            RJ = j_object(RW),
            lookup_member(RW, "index", IJ), IJ = j_int(I),
            lookup_member(RW, "cause", CJ), CJ = j_int(C),
            C >= 0i64, C =< 4294967295i64
        then
            rewrite_nth_withdraw(int64.cast_to_int(I),
                uint32.cast_from_uint64(uint64.cast_from_int64(C)),
                Records, Rewritten, Found),
            (
                Found = yes,
                Rewrite = rewrite_done(Rewritten)
            ;
                Found = no,
                Rewrite = rewrite_missing(string.format(
                    "rewrite_withdraw_cause: the run has no withdrawal %d",
                    [i(int64.cast_to_int(I))]))
            )
        else
            Rewrite = rewrite_missing("rewrite_withdraw_cause: want "
                ++ "{\"index\": <int>, \"cause\": <uint32>}")
        )
    else
        Rewrite = rewrite_none
    ).

:- pred rewrite_nth_withdraw(int::in, uint32::in,
    list({seq, stream_event})::in, list({seq, stream_event})::out,
    bool::out) is det.

rewrite_nth_withdraw(_, _, [], [], no).
rewrite_nth_withdraw(I, Code, [Rec | Recs], Out, Found) :-
    Rec = {S, Ev},
    ( if Ev = se_fact_withdraw(Id, _) then
        ( if I = 0 then
            Out = [{S, se_fact_withdraw_unnamed(Id, Code)} | Recs],
            Found = yes
        else
            rewrite_nth_withdraw(I - 1, Code, Recs, Out0, Found),
            Out = [Rec | Out0]
        )
    else
        rewrite_nth_withdraw(I, Code, Recs, Out0, Found),
        Out = [Rec | Out0]
    ).

    % The cause of every `FactWithdraw` the decoded recording holds, in stream
    % order, by its name in `FactWithdraw.Cause` ([RFCS.7a.2]). A cause the
    % enum does not name reads back as `CAUSE_<n>`, as `runner.py` spells it.
    %
:- func withdraw_cause_names(list({seq, stream_event})) = list(string).

withdraw_cause_names(Events) = list.filter_map(
    ( func(Rec) = Name is semidet :-
        Rec = {_, Ev},
        (
            Ev = se_fact_withdraw(_, Cause),
            Name = fwth_cause_name(Cause)
        ;
            Ev = se_fact_withdraw_unnamed(_, Code),
            Name = "CAUSE_" ++ string.from_int(uint32.cast_to_int(Code))
        ) ),
    Events).

    % `FactWithdraw.Cause`'s names. A decoded FactWithdraw never reads back as
    % `rc_hydration_ttl` (TTL_EXPIRED decodes as `rc_ttl`) or `rc_explicit`
    % (a host retract is a FactRetract), but every constructor is named so a new
    % cause is a compile error here.
    %
:- func fwth_cause_name(retract_cause) = string.

fwth_cause_name(rc_explicit) = "CAUSE_UNSPECIFIED".
fwth_cause_name(rc_justifier_end) = "JUSTIFIER_ENDED".
fwth_cause_name(rc_ttl) = "TTL_EXPIRED".
fwth_cause_name(rc_hydration_ttl) = "TTL_EXPIRED".
fwth_cause_name(rc_supersede) = "SUPERSEDED".
fwth_cause_name(rc_synthetic_discharged) = "SYNTHETIC_DISCHARGED".
fwth_cause_name(rc_author_withdrawn) = "AUTHOR_WITHDRAWN".
fwth_cause_name(rc_activation_completed) = "ACTIVATION_COMPLETED".

    % `pbf_framing` [RFCS.16]-[RFCS.20]: `PBF_FRAMING_VECTORS.json`'s groups,
    % through this runtime's framing, `ds.atom` and `ds.wire`. `run_fixture`
    % attaches the file as the expectation's `corpus`.
    %
    %   encode  `put_delimited(1, put_delimited(field, body))` equals the
    %           vector's prefix + body, and the registry names `field` with
    %           the vector's `atom`, its body message.
    %   band    `band_of`, whether `atom_of_field` knows the number, and the
    %           disposition (`skip` for a known atom, else
    %           `disposition_of_unknown`) equal the vector's.
    %   decode  the `next_frame` walk yields each atom's (field, body length,
    %           end offset) in order; the walk ends at EOF or malformed as the
    %           vector's `terminal` says, a half-written tail being EOF
    %           [RFCS.19.2]; and the container is decided by the first atom's
    %           number [RFCS.19.4].
    %
    % The vectors' protobuf-parser and strict-reader legs are `runner.py`'s
    % alone; here there is no protobuf parser and no strict reader.
    %
:- func pbf_framing_result(string, json_members) = behave_result.

pbf_framing_result(Kind, Expect) = Result :-
    ( if
        lookup_member(Expect, "corpus", CJ), CJ = j_object(Corpus),
        Groups = string_array(array_member(Expect, "groups")),
        Groups = [_ | _]
    then
        ( if
            list.find_first_map(
                (pred(G::in, Why::out) is semidet :-
                    ( if lookup_member(Corpus, G, GJ), GJ = j_object(GMs) then
                        Vectors = array_member(GMs, "vectors"),
                        list.find_first_map(pbf_vector_failure(G), Vectors,
                            Why)
                    else
                        Why = "the corpus has no group `" ++ G ++ "`"
                    )),
                Groups, Failure)
        then
            Result = behave_result(bo_fail, Kind, Failure)
        else
            Result = behave_result(bo_pass, Kind, "")
        )
    else
        Result = behave_result(bo_unsupported, Kind,
            "no framing corpus attached, or no `groups`")
    ).

:- pred pbf_vector_failure(string::in, json::in, string::out) is semidet.

pbf_vector_failure(Group, j_object(V), Why) :-
    Name = ( if lookup_member(V, "name", NJ), NJ = j_string(N) then N
             else if int_member(V, "field", F0) then string.int_to_string(F0)
             else "?" ),
    ( if Group = "encode" then
        encode_vector_failure(V, Detail)
    else if Group = "band" then
        band_vector_failure(V, Detail)
    else if Group = "decode" then
        decode_vector_failure(V, Detail)
    else
        Detail = "no driver for this group"
    ),
    Why = Group ++ "/" ++ Name ++ ": " ++ Detail.

:- pred encode_vector_failure(json_members::in, string::out) is semidet.

encode_vector_failure(V, Why) :-
    ( if
        int_member(V, "field", Field), Field > 0,
        lookup_member(V, "prefix_hex", PJ), PJ = j_string(PrefixHex),
        hex_bytes(PrefixHex, Prefix),
        vector_body(V, Body)
    then
        put_delimited(uint32.det_from_int(Field), Body, init_builder, Inner),
        put_delimited(1u32, builder_bytes(Inner), init_builder, Outer),
        ( if builder_bytes(Outer) \= Prefix ++ Body then
            Why = "the frame differs from prefix + body"
        else if not (lookup_member(V, "atom", AJ), AJ = j_string(_)) then
            % Not a pass: a row that names no atom would fall through the
            % name check below to `fail`.
            Why = "the vector names no `atom`"
        else if
            lookup_member(V, "atom", MJ), MJ = j_string(Message),
            not (
                atom_of_field(uint32.det_from_int(Field), Id),
                atom_message(Id) = Message
            )
        then
            Why = "the registry does not name field "
                ++ string.int_to_string(Field) ++ " " ++ Message
        else
            fail
        )
    else
        Why = "a vector this driver cannot read"
    ).

:- pred band_vector_failure(json_members::in, string::out) is semidet.

band_vector_failure(V, Why) :-
    ( if
        int_member(V, "field", Field), Field >= 0,
        lookup_member(V, "band", BJ), BJ = j_string(WantBand),
        lookup_member(V, "known", KJ), KJ = j_bool(WantKnown),
        lookup_member(V, "disposition", DJ), DJ = j_string(WantDisp)
    then
        U = uint32.det_from_int(Field),
        GotBand = band_name(band_of(U)),
        GotKnown = ( if atom_of_field(U, _) then yes else no ),
        GotDisp = ( if GotKnown = yes then "skip"
                    else disposition_name(disposition_of_unknown(U)) ),
        ( if GotBand \= WantBand then
            Why = "band " ++ GotBand ++ ", vector says " ++ WantBand
        else if GotKnown \= WantKnown then
            Why = "known " ++ string.string(GotKnown) ++ ", vector says "
                ++ string.string(WantKnown)
        else if GotDisp \= WantDisp then
            Why = "disposition " ++ GotDisp ++ ", vector says " ++ WantDisp
        else
            fail
        )
    else
        Why = "a vector this driver cannot read"
    ).

:- pred decode_vector_failure(json_members::in, string::out) is semidet.

decode_vector_failure(V, Why) :-
    ( if
        lookup_member(V, "hex", HJ), HJ = j_string(Hex), hex_bytes(Hex, Raw),
        lookup_member(V, "terminal", TJ), TJ = j_string(WantTerminal),
        lookup_member(V, "container", CJ), CJ = j_string(WantContainer),
        list.map(
            (pred(A::in, T::out) is semidet :-
                A = j_object(AMs),
                int_member(AMs, "field", F),
                int_member(AMs, "body_len", L),
                int_member(AMs, "next", N),
                T = {F, L, N}),
            array_member(V, "atoms"), WantAtoms)
    then
        walk_frames(init_reader(from_bytes(Raw)), [], GotAtoms, Terminal),
        GotContainer = container_name(GotAtoms, Terminal),
        ( if GotAtoms \= WantAtoms then
            Why = "atoms " ++ string.string(GotAtoms) ++ ", vector says "
                ++ string.string(WantAtoms)
        else if Terminal \= WantTerminal then
            Why = "the walk ends " ++ Terminal ++ ", vector says "
                ++ WantTerminal
        else if GotContainer \= WantContainer then
            Why = "container " ++ GotContainer ++ ", vector says "
                ++ WantContainer
        else
            fail
        )
    else
        Why = "a vector this driver cannot read"
    ).

    % Every frame's (field number, body length, end offset), and how the walk
    % ended: "eof" or "malformed".
    %
:- pred walk_frames(reader::in, list({int, int, int})::in,
                    list({int, int, int})::out, string::out) is det.

walk_frames(R0, Acc, Atoms, Terminal) :-
    next_frame(Res, R0, R1),
    (
        Res = fr_ok(frame(Ref, Body, _)),
        ( if Ref = unknown(N), band_of(N) = band_none then
            % A number in no band, 0 or 2048+, is malformed. `next_frame`
            % leaves the band to its caller.
            Atoms = list.reverse(Acc),
            Terminal = "malformed"
        else
            Field = ( if Ref = known(Id)
                      then uint32.cast_to_int(atom_field(Id))
                      else if Ref = unknown(N) then uint32.cast_to_int(N)
                      else 0 ),
            walk_frames(R1, [{Field, remaining(Body), position(R1)} | Acc],
                Atoms, Terminal)
        )
    ;
        Res = fr_eof,
        Atoms = list.reverse(Acc),
        Terminal = "eof"
    ;
        Res = fr_error(Err, _),
        Atoms = list.reverse(Acc),
        % The vectors describe the incremental stream reader, which this walk
        % plays: a partial trailing atom is EOF to it ([RFCS.19.2]). So the
        % outer frame's truncation is EOF, and anything else is malformed, a
        % body cut short inside a complete frame (`ae_body`) included.
        ( if Err = ae_wire(we_truncated) then
            Terminal = "eof"
        else
            Terminal = "malformed"
        )
    ).

    % [RFCS.19.4]: the container is the first atom's number: 263 a DSC, 258 a
    % stream, anything else (or nothing, or bytes that do not frame) unknown.
    %
:- func container_name(list({int, int, int}), string) = string.

container_name(Atoms, Terminal) =
    ( if Terminal = "malformed" then "unknown"
      else if Atoms = [{263, _, _} | _] then "dsc"
      else if Atoms = [{258, _, _} | _] then "stream"
      else "unknown" ).

:- func band_name(band) = string.

band_name(band_inject) = "inject".
band_name(band_reject) = "reject".
band_name(band_skip) = "skip".
band_name(band_none) = "none".

:- func disposition_name(disposition) = string.

disposition_name(disp_skip) = "skip".
disposition_name(disp_reject_inject) = "reject_inject".
disposition_name(disp_reject_version) = "reject_version".
disposition_name(disp_malformed) = "malformed".

:- pred vector_body(json_members::in, list(uint8)::out) is semidet.

vector_body(V, Body) :-
    ( if lookup_member(V, "body_fill", FJ), FJ = j_object(Fill) then
        lookup_member(Fill, "byte", BJ), BJ = j_string(ByteHex),
        hex_bytes(ByteHex, [Byte]),
        int_member(Fill, "len", Len),
        Body = list.duplicate(Len, Byte)
    else if lookup_member(V, "body_hex", HJ), HJ = j_string(Hex) then
        hex_bytes(Hex, Body)
    else
        Body = []
    ).

:- pred hex_bytes(string::in, list(uint8)::out) is semidet.

hex_bytes(Hex, Bytes) :-
    hex_pairs(string.to_char_list(Hex), Bytes).

:- pred hex_pairs(list(char)::in, list(uint8)::out) is semidet.

hex_pairs([], []).
hex_pairs([H, L | Rest], [B | Bs]) :-
    char.hex_digit_to_int(H, HI),
    char.hex_digit_to_int(L, LI),
    B = uint8.det_from_int(HI * 16 + LI),
    hex_pairs(Rest, Bs).

    % `rfcs_artefact_strip` [LFST.8]: a recording read without the rule
    % artefact recovers each fact's envelope and typed slots, and they agree
    % with the artefact's account. `decode_stream` takes no schema table and
    % rebuilds each schema from the stream's `SchemaDef` and `Slot` atoms
    % [RFCS.5.1], so every `FactAssert` the engine asserted is compared with
    % its decoded counterpart on `fact_id`, `seq`, schema name ([LFST.8.2])
    % and slot values ([LFST.8.10]), strings expanded through each side's own
    % intern table. The schema is compared by name because a decoded
    % `schema_id` is counted from 1 in `SchemaDef` arrival order.
    %
:- func artefact_strip_result(string, program, engine, list(stamped))
    = behave_result.

artefact_strip_result(Kind, P, E, Stamped) = Result :-
    list.foldl2(number_step, Stamped, init_recorder, _, [], RevAll),
    Records = list.map((func({S, _, Ev}) = {S, Ev}), list.reverse(RevAll)),
    Meta = session_header(E),
    encode_recording(Meta, rfcs_ctx(schemas(P), engine_interns(E)),
        from_ns(0u64), prelude_seeds(E), list.map(record_event, Records),
        Bytes, Unencodable),
    decode_stream(from_bytes(Bytes), init_interns, Decoded),
    Want = list.filter_map(
        (func({S, Ev}) = {S, Id, Name, Vs} is semidet :-
            Ev = se_fact_assert(Id, Sid, Values, _),
            program_schema_name(P, Sid, Name),
            Vs = list.map(comparable(engine_interns(E)), Values)),
        Records),
    % An event the writer could not encode is missing from a stream that
    % decodes cleanly, so it fails here, before the decode is looked at.
    ( if Unencodable = [_ | _] then
        Result = behave_result(bo_fail, Kind,
            "the recorder could not encode: " ++ string.string(Unencodable))
    else
        (
            Decoded = decode_failed(Clause, Offset),
            Result = behave_result(bo_fail, Kind,
                string.format("the recording does not decode: %s at %d",
                    [s(Clause), i(Offset)]))
        ;
            Decoded = unannounced_schema(_, USeq, UOffset),
            Result = behave_result(bo_fail, Kind,
                string.format("the recording's FactAssert at seq %s (byte %d) "
                    ++ "names a schema no SchemaDef announced ([RFCS.5.4])",
                    [s(string.string(USeq)), i(UOffset)]))
        ;
            Decoded = decoded(DS),
            Got = list.filter_map(
                (func({S, Ev}) = {S, Id, Name, Vs} is semidet :-
                    Ev = se_fact_assert(Id, Sid, Values, _),
                    list.index0(DS ^ dsm_schemas,
                        uint32.cast_to_int(schema_id_value(Sid)) - 1, Name),
                    Vs = list.map(comparable(DS ^ dsm_interns), Values)),
                DS ^ dsm_events),
            ( if Want = [] then
                Result = behave_result(bo_fail, Kind,
                    "no FactAssert in the run (need an assert step)")
            else if Got = Want then
                Result = behave_result(bo_pass, Kind, "")
            else
                Result = behave_result(bo_fail, Kind,
                    "the stripped decode disagrees with the run: asserted "
                        ++ string.string(Want) ++ ", decoded "
                        ++ string.string(Got))
            )
        )
    ).

:- pred program_schema_name(program::in, schema_id::in, string::out)
    is semidet.

program_schema_name(P, Id, Name) :-
    list.find_first_match((pred(S::in) is semidet :- S ^ s_id = Id),
        schemas(P), Schema),
    expand(interns(P), schema_name_ref(Schema ^ s_name), Name).

    % A value with any interned string expanded, so two tables compare.
    %
:- func comparable(intern_table, ds_value) = ds_value.

comparable(IT, V) =
    ( if V = str(Ref), expand(IT, Ref, S) then text(S) else V ).

    % The byte offset at which each frame begins, in order.
    %
:- pred frame_starts(reader::in, list(int)::in, list(int)::out) is det.

frame_starts(R0, Acc, Starts) :-
    Pos = position(R0),
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(_) then
        frame_starts(R1, [Pos | Acc], Starts)
    else
        Starts = list.reverse(Acc)
    ).

    % The body messages of the known atoms, in order; an unknown atom is
    % skipped.
    %
:- func known_atom_names(reader, list(string)) = list(string).

known_atom_names(R0, Acc) = Names :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), _, _)) then
        Names = known_atom_names(R1, [atom_message(Id) | Acc])
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Names = known_atom_names(R1, Acc)
    else
        Names = list.reverse(Acc)
    ).

    % Each `CallIssued` atom's `correlation` (field 3), in order. An atom
    % with no field 3 gives `""`, which is proto3's absence; one whose fields
    % do not parse gives a string no correlation can be, so the comparison
    % fails rather than the walk stopping.
    %
:- func call_correlations(reader, list(string)) = list(string).

call_correlations(R0, Acc) = Corrs :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if Id = at_call_issued then
            ( if fold_fields(Body, call_corr_field, "", ff_ok(C)) then
                Corr = C
            else
                Corr = "<a CallIssued body that does not parse>"
            ),
            Corrs = call_correlations(R1, [Corr | Acc])
        else
            Corrs = call_correlations(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Corrs = call_correlations(R1, Acc)
    else
        Corrs = list.reverse(Acc)
    ).

    % Each `FactAssert` atom's `event_id` (field 8), in order, for
    % `expected_event_ids` ([RCTS.1.2.23]). An atom with no field 8 gives
    % `""`, proto3's absence; one whose fields do not parse gives a string no
    % UUID can be, so the comparison fails rather than the walk stopping.
    %
:- func fact_assert_event_ids(reader, list(string)) = list(string).

fact_assert_event_ids(R0, Acc) = Ids :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if Id = at_fact_assert then
            ( if fold_fields(Body, event_id_field, "", ff_ok(E)) then
                EventId = E
            else
                EventId = "<a FactAssert body that does not parse>"
            ),
            Ids = fact_assert_event_ids(R1, [EventId | Acc])
        else
            Ids = fact_assert_event_ids(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Ids = fact_assert_event_ids(R1, Acc)
    else
        Ids = list.reverse(Acc)
    ).

    % Every `FactAssert`, `FactEmit` and `FactWithdraw` atom (`fact_id_atoms`),
    % in order, as its message's name and its `fact_id` (field 1 of each), for
    % `expected_fact_ids` ([RCTS.1.2.23], [RFCS.6.9]). An atom with no field
    % 1 gives 0, proto3's absence, which names no fact; one whose fields do
    % not parse gives -1, which no id is, so the comparison fails rather than
    % the walk stopping.
    %
:- func recorded_fact_ids(reader, list({string, int64})) = list({string, int64}).

recorded_fact_ids(R0, Acc) = Ids :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if list.member(Id, fact_id_atoms) then
            ( if fold_fields(Body, fact_id_field, 0u64, ff_ok(F)) then
                FactId = int64.cast_from_uint64(F)
            else
                FactId = -1i64
            ),
            Ids = recorded_fact_ids(R1, [{atom_message(Id), FactId} | Acc])
        else
            Ids = recorded_fact_ids(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Ids = recorded_fact_ids(R1, Acc)
    else
        Ids = list.reverse(Acc)
    ).

:- pred fact_id_field(uint32::in, field_value::in, uint64::in, uint64::out)
    is semidet.

fact_id_field(N, V, F0, F) :-
    ( if N = 1u32 then
        V = fv_varint(F)
    else
        F = F0
    ).

    % Every `FactEmit` atom, in order, as its `rule_name` (field 5), for
    % `expected_emits` ([RCTS.1.2.23], [RFCS.6a.2]). An absent field gives
    % proto3's default, ""; an
    % atom whose fields do not parse gives a name no rule can have, so the
    % comparison fails rather than the walk stopping.
    %
:- func recorded_emits(reader, list(string)) = list(string).

recorded_emits(R0, Acc) = Emits :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if Id = at_fact_emit then
            ( if fold_fields(Body, emit_field, "", ff_ok(E)) then
                Emit = E
            else
                Emit = "<a FactEmit body that does not parse>"
            ),
            Emits = recorded_emits(R1, [Emit | Acc])
        else
            Emits = recorded_emits(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Emits = recorded_emits(R1, Acc)
    else
        Emits = list.reverse(Acc)
    ).

:- pred emit_field(uint32::in, field_value::in, string::in, string::out)
    is semidet.

emit_field(N, V, Rule0, Rule) :-
    ( if N = 5u32 then
        V = fv_bytes(R),
        reader_string(R, Rule)
    else
        Rule = Rule0
    ).

    % Every `FactPublish` atom, in order, as its `schema_name` (field 1) and
    % its `rule_name` (field 2), for `expected_publishes` ([RCTS.1.2.23],
    % [RFCS.27.1]): what `runner.py`'s `_recorded_publishes` reads off each
    % atom's message through libds's reader. An absent field gives proto3's
    % default, ""; an atom whose fields do not parse gives a schema no program
    % can declare, so the comparison fails rather than the walk stopping.
    %
:- func recorded_publishes(reader, list({string, string}))
    = list({string, string}).

recorded_publishes(R0, Acc) = Pubs :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if Id = at_fact_publish then
            ( if fold_fields(Body, publish_field, {"", ""}, ff_ok(P)) then
                Pub = P
            else
                Pub = {"<a FactPublish body that does not parse>", ""}
            ),
            Pubs = recorded_publishes(R1, [Pub | Acc])
        else
            Pubs = recorded_publishes(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Pubs = recorded_publishes(R1, Acc)
    else
        Pubs = list.reverse(Acc)
    ).

:- pred publish_field(uint32::in, field_value::in, {string, string}::in,
    {string, string}::out) is semidet.

publish_field(N, V, {Schema0, Rule0}, {Schema, Rule}) :-
    ( if N = 1u32 then
        V = fv_bytes(R),
        reader_string(R, Schema),
        Rule = Rule0
    else if N = 2u32 then
        V = fv_bytes(R),
        reader_string(R, Rule),
        Schema = Schema0
    else
        Schema = Schema0,
        Rule = Rule0
    ).

    % Every `CacheSeed` atom, in order, as its `key` (field 1), `value_json`
    % (field 2) and `deadline_ns` (field 3), for `expected_cache_seeds`
    % ([RCTS.1.2.23], [RFCS.26.1]). An absent field gives proto3's default,
    % "" or 0; an atom whose fields do not parse gives a key no seed can
    % have, so the comparison fails rather than the walk stopping.
    %
:- func recorded_cache_seeds(reader, list({string, string, int64}))
    = list({string, string, int64}).

recorded_cache_seeds(R0, Acc) = Seeds :-
    next_frame(Res, R0, R1),
    ( if Res = fr_ok(frame(known(Id), Body, _)) then
        ( if Id = at_cache_seed then
            ( if
                fold_fields(Body, seed_field, {"", "", 0u64},
                    ff_ok({K, V, D}))
            then
                Seed = {K, V, int64.cast_from_uint64(D)}
            else
                Seed = {"<a CacheSeed body that does not parse>", "", -1i64}
            ),
            Seeds = recorded_cache_seeds(R1, [Seed | Acc])
        else
            Seeds = recorded_cache_seeds(R1, Acc)
        )
    else if Res = fr_ok(frame(unknown(_), _, _)) then
        Seeds = recorded_cache_seeds(R1, Acc)
    else
        Seeds = list.reverse(Acc)
    ).

:- pred seed_field(uint32::in, field_value::in, {string, string, uint64}::in,
    {string, string, uint64}::out) is semidet.

seed_field(N, V, {K0, J0, D0}, {K, J, D}) :-
    ( if N = 1u32 then
        V = fv_bytes(R),
        reader_string(R, K),
        J = J0,
        D = D0
    else if N = 2u32 then
        V = fv_bytes(R),
        reader_string(R, J),
        K = K0,
        D = D0
    else if N = 3u32 then
        V = fv_varint(D),
        K = K0,
        J = J0
    else
        K = K0,
        J = J0,
        D = D0
    ).

    % One `expected_cache_seeds` entry as `recorded_cache_seeds` gives it; an
    % entry `cache_seed_entry_shape` refuses never reaches here.
    %
:- func cache_seed_entry(json) = {string, string, int64} is semidet.

cache_seed_entry(J) = {Key, Value, Deadline} :-
    J = j_object(Ms),
    lookup_member(Ms, "key", KeyJ),
    KeyJ = j_string(Key),
    lookup_member(Ms, "value_json", ValueJ),
    ValueJ = j_string(Value),
    lookup_member(Ms, "deadline_ns", DeadlineJ),
    DeadlineJ = j_int(Deadline).

    % One `expected_emits` entry as `recorded_emits` gives it; an entry
    % `emit_entry_shape` refuses never reaches here.
    %
:- func emit_entry(json) = string is semidet.

emit_entry(J) = Rule :-
    J = j_object(Ms),
    lookup_member(Ms, "rule_name", RuleJ),
    RuleJ = j_string(Rule).

    % One `expected_publishes` entry as `recorded_publishes` gives it; an
    % entry `publish_entry_shape` refuses never reaches here.
    %
:- func publish_entry(json) = {string, string} is semidet.

publish_entry(J) = {Schema, Rule} :-
    J = j_object(Ms),
    lookup_member(Ms, "schema_name", SchemaJ),
    SchemaJ = j_string(Schema),
    lookup_member(Ms, "rule_name", RuleJ),
    RuleJ = j_string(Rule).

    % One `expected_fact_ids` entry as `recorded_fact_ids` gives it; an entry
    % `fact_id_entry_shape` refuses never reaches here.
    %
:- func fact_id_entry(json) = {string, int64} is semidet.

fact_id_entry(J) = {Name, Id} :-
    J = j_object(Ms),
    lookup_member(Ms, "atom", AtomJ),
    AtomJ = j_string(Name),
    lookup_member(Ms, "fact_id", IdJ),
    IdJ = j_int(Id).

:- pred event_id_field(uint32::in, field_value::in, string::in, string::out)
    is semidet.

event_id_field(N, V, E0, E) :-
    ( if N = 8u32 then
        V = fv_bytes(R),
        reader_string(R, E)
    else
        E = E0
    ).

:- pred call_corr_field(uint32::in, field_value::in, string::in, string::out)
    is semidet.

call_corr_field(N, V, C0, C) :-
    ( if N = 3u32 then
        V = fv_bytes(R),
        reader_string(R, C)
    else
        C = C0
    ).

    % `rfcs_roundtrip`'s `expected_slots` ([RFCS.5.1]): every `Slot` atom of
    % the named schemas, in stream order, as an object of the fields it
    % carries, by their `proto/slot.proto` names. Only the fields present:
    % proto3 omits a zero. An enum reads as its number, a `bool` as a Json
    % Bool, `tolerance` as a Float. A field number `proto/slot.proto` does
    % not allocate is ignored. Fails on a frame or a body that does not
    % parse.
    %
:- pred announced_slots(reader::in, list(string)::in, list(json)::in,
    list(json)::out) is semidet.

announced_slots(R0, Schemas, Acc, Slots) :-
    next_frame(Res, R0, R1),
    (
        Res = fr_ok(frame(Atom, Body, _)),
        ( if Atom = known(at_slot) then
            fold_fields(Body, slot_json_field, [], ff_ok(Members)),
            ( if
                assoc_list.search(Members, "schema_name", j_string(Schema)),
                list.member(Schema, Schemas)
            then
                Acc1 = [j_object(object(Members)) | Acc]
            else
                Acc1 = Acc
            )
        else
            Acc1 = Acc
        ),
        announced_slots(R1, Schemas, Acc1, Slots)
    ;
        Res = fr_eof,
        Slots = list.reverse(Acc)
    ).

:- pred slot_json_field(uint32::in, field_value::in,
    assoc_list(string, json)::in, assoc_list(string, json)::out) is semidet.

slot_json_field(Num, Value, Ms0, Ms) :-
    ( if slot_field_name(Num, Name) then
        (
            Value = fv_bytes(R),
            reader_string(R, S),
            J = j_string(S)
        ;
            Value = fv_varint(V),
            ( if ( Num = 5u32 ; Num = 6u32 ; Num = 11u32 ) then
                J = j_bool(( if V = 0u64 then no else yes ))
            else
                J = j_int(int64.cast_from_uint64(V))
            )
        ;
            Value = fv_fixed64(Bits),
            J = j_float(float_from_bits(Bits))
        ),
        Ms = [Name - J | Ms0]
    else
        Ms = Ms0
    ).

    % `proto/slot.proto#Slot`'s field names, by number. 8 is `reserved`.
    %
:- pred slot_field_name(uint32::in, string::out) is semidet.

slot_field_name(1u32, "schema_name").
slot_field_name(2u32, "slot_name").
slot_field_name(3u32, "kind").
slot_field_name(4u32, "schema_ref").
slot_field_name(5u32, "sampled").
slot_field_name(6u32, "retained").
slot_field_name(7u32, "tolerance").
slot_field_name(9u32, "identity_role").
slot_field_name(10u32, "module_id").
slot_field_name(11u32, "nullable").
slot_field_name(12u32, "capacity").

    % The schema an `expected_slots` entry names.
    %
:- func slot_schema_name(json) = string is semidet.

slot_schema_name(J) = Name :-
    J = j_object(Ms),
    lookup_member(Ms, "schema_name", j_string(Name)).

:- pred schema_def_before_fact_assert(list(string)::in, bool::in) is semidet.

schema_def_before_fact_assert([], _).
schema_def_before_fact_assert([A | As], Seen) :-
    ( if A = "SchemaDef" then
        schema_def_before_fact_assert(As, yes)
    else if A = "FactAssert" then
        Seen = yes,
        schema_def_before_fact_assert(As, Seen)
    else
        schema_def_before_fact_assert(As, Seen)
    ).

:- func replay_step_effects(replay_step) = list(effect).

replay_step_effects(delivered(In)) = In.
replay_step_effects(pumped(Pump)) = Pump.
replay_step_effects(unknown_schema(_)) = [].
replay_step_effects(unknown_fact_id(_)) = [].
replay_step_effects(recording_incomplete(_)) = [].
replay_step_effects(binding_refused(_, _)) = [].
replay_step_effects(diverged(_)) = [].
replay_step_effects(input_refused(_, _, _)) = [].

:- func non_tick_events(list(effect)) = list(stream_event).

non_tick_events(Effects) =
    list.filter_map(
        (func(Eff) = Ev is semidet :-
            Eff = eff_event(Ev),
            not Ev = se_clock_tick(_, _)),
        Effects).

:- func first_divergence(list(stream_event), list(stream_event), int)
    = string.

first_divergence([], [], _) = "streams equal".
first_divergence([], [G | _], I) =
    string.format("replay has an extra event at %d: %s",
        [i(I), s(string.string(G))]).
first_divergence([W | _], [], I) =
    string.format("replay stops before event %d: %s",
        [i(I), s(string.string(W))]).
first_divergence([W | Ws], [G | Gs], I) =
    ( if W = G then
        first_divergence(Ws, Gs, I + 1)
    else
        string.format("divergence at %d: recorded %s, replayed %s",
            [i(I), s(string.string(W)), s(string.string(G))])
    ).

    % `introspection_assert`: every entry of `checks` names a surface and one
    % assertion, and the first that does not hold fails the fixture.
    %
    %   `fact_count`       -- `engine_fact_count`, the live author facts.
    %   `justifiers`       -- the rule names justifying `fact_id`, as a sorted
    %                         multiset; `justifier_count` -- how many.
    %   `rete_network`     -- node and edge counts at least `min_nodes` /
    %                         `min_edges`.
    %   `slot_schema_ref`  -- the schema slot `schema`.`slot` names as its
    %                         reference, `null` for none (`slot_reference`).
    %
    % `fact_id` is the engine's id, which `ds.wm` issues from 1 in assertion
    % and emit order.
    %
    % The network's edges are counted as wiring: one per beta's right alpha,
    % one per beta with a left parent, one per terminal's beta. libds's
    % `rete_network` export may count otherwise; the corpus pins only lower
    % bounds.
    %
:- func introspection_result(string, json_members, program, engine)
    = behave_result.

introspection_result(Kind, Expect, P, E) = Result :-
    Checks = array_member(Expect, "checks"),
    ( if
        list.find_first_map(
            (pred(C::in, Why::out) is semidet :-
                introspection_failure(P, E, C, Why)),
            Checks, Failure)
    then
        Result = behave_result(bo_fail, Kind, Failure)
    else if
        list.find_first_match(
            (pred(C::in) is semidet :- not known_surface(C)),
            Checks, _)
    then
        Result = behave_result(bo_unsupported, Kind,
            "an introspection check on a surface this driver does not read")
    else
        Result = behave_result(bo_pass, Kind, "")
    ).

:- pred known_surface(json::in) is semidet.

known_surface(j_object(Ms)) :-
    lookup_member(Ms, "surface", SJ),
    SJ = j_string(S),
    ( S = "fact_count" ; S = "justifiers" ; S = "justifier_count"
    ; S = "rete_network" ; S = "slot_schema_ref" ).

    % Why a check does not hold. Fails when it holds, or when its surface is
    % one this driver does not read (`known_surface`).
    %
:- pred introspection_failure(program::in, engine::in, json::in, string::out)
    is semidet.

introspection_failure(P, E, j_object(Ms), Why) :-
    lookup_member(Ms, "surface", SurfaceJ),
    SurfaceJ = j_string(Surface),
    ( if Surface = "fact_count", int_member(Ms, "equals", Want) then
        Got = engine_fact_count(E),
        Got \= Want,
        Why = string.format("introspection fact_count: want %d, got %d",
            [i(Want), i(Got)])
    else if
        ( Surface = "justifiers" ; Surface = "justifier_count" ),
        int_member(Ms, "fact_id", Id),
        Id >= 1
    then
        Rules = justifier_rules(P, E, Id),
        ( if Surface = "justifier_count" then
            int_member(Ms, "count", Want),
            list.length(Rules) \= Want,
            Why = string.format(
                "justifier_count(fact_id=%d): want %d, got %d",
                [i(Id), i(Want), i(list.length(Rules))])
        else
            Want = list.sort(string_array(array_member(Ms, "expect_rules"))),
            Rules \= Want,
            Why = string.format("justifiers(fact_id=%d): want %s, got %s",
                [i(Id), s(string.string(Want)), s(string.string(Rules))])
        )
    else if
        Surface = "slot_schema_ref",
        lookup_member(Ms, "schema", SchemaJ), SchemaJ = j_string(SchemaName),
        lookup_member(Ms, "slot", SlotJ), SlotJ = j_string(SlotName),
        lookup_member(Ms, "equals", WantJ),
        ( WantJ = j_null, Want = no
        ; WantJ = j_string(W), Want = yes(W)
        )
    then
        ( if slot_reference(P, E, SchemaName, SlotName, Got) then
            Got \= Want,
            Why = string.format("slot_schema_ref %s.%s: want %s, got %s",
                [s(SchemaName), s(SlotName), s(string.string(Want)),
                 s(string.string(Got))])
        else
            Why = string.format("slot_schema_ref: no slot %s.%s",
                [s(SchemaName), s(SlotName)])
        )
    else
        Surface = "rete_network",
        Net = network(P),
        Nodes = list.length(alpha_nodes(Net)) + list.length(beta_nodes(Net))
            + list.length(terminal_nodes(Net)),
        Edges = list.length(beta_nodes(Net))
            + list.length(list.filter(
                (pred(B::in) is semidet :- B ^ bn_parent = yes(_)),
                beta_nodes(Net)))
            + list.length(terminal_nodes(Net)),
        ( if int_member(Ms, "min_nodes", MinN), Nodes < MinN then
            Why = string.format("rete_network nodes: want >= %d, got %d",
                [i(MinN), i(Nodes)])
        else
            int_member(Ms, "min_edges", MinE),
            Edges < MinE,
            Why = string.format("rete_network edges: want >= %d, got %d",
                [i(MinE), i(Edges)])
        )
    ).

    % The schema the loaded slot `Schema`.`Slot` names as its reference, `no`
    % for none: a slot holds one exactly when its kind is `k_schema`
    % ([RDSC.5.5.5], [NFCT.1.4.1]). Fails when there is no such slot.
    %
:- pred slot_reference(program::in, engine::in, string::in, string::in,
    maybe(string)::out) is semidet.

slot_reference(P, E, Schema, Slot, Ref) :-
    IT = engine_interns(E),
    list.find_first_match(
        (pred(S::in) is semidet :- expand(IT, schema_name_ref(S ^ s_name), Schema)),
        schemas(P), Found),
    list.find_first_match(
        (pred(C::in) is semidet :- expand(IT, C ^ sc_name, Slot)),
        slot_commons(Found), Common),
    ( if
        Common ^ sc_kind = k_schema(RefName),
        expand(IT, schema_name_ref(RefName), R)
    then
        Ref = yes(R)
    else
        Ref = no
    ).

    % The rule name of every live justification of a fact, sorted.
    %
:- func justifier_rules(program, engine, int) = list(string).

justifier_rules(P, E, Id) = list.sort(Names) :-
    IT = engine_interns(E),
    Terminals = justifying_terminals(engine_tms(E),
        make_fact_id(uint64.det_from_int(Id))),
    Names = list.filter_map(
        (func(T) = Name is semidet :-
            list.find_first_match(
                (pred(TN::in) is semidet :-
                    node_id_value(TN ^ tn_id) = T),
                terminal_nodes(network(P)), Node),
            expand(IT, Node ^ tn_rule, Name)),
        Terminals).

:- pred number_step(stamped::in, recorder::in, recorder::out,
    list({seq, instant, stream_event})::in,
    list({seq, instant, stream_event})::out) is det.

number_step({Clock, Effects}, !R, !Acc) :-
    list.foldl2(
        (pred(Eff::in, R0::in, R1::out, A0::in, A1::out) is det :-
            ( if Eff = eff_event(Ev) then
                record(Ev, S, R0, R1),
                A1 = [{S, Clock, Ev} | A0]
            else
                R1 = R0,
                A1 = A0
            )),
        Effects, !R, !Acc).

:- pred strictly_increasing(list(int)::in) is semidet.

strictly_increasing([]).
strictly_increasing([_]).
strictly_increasing([A, B | Rest]) :-
    A < B,
    strictly_increasing([B | Rest]).

:- pred steps_by(int::in, list(int)::in) is semidet.

steps_by(_, []).
steps_by(_, [_]).
steps_by(Step, [A, B | Rest]) :-
    B - A = Step,
    steps_by(Step, [B | Rest]).

:- func event_kind(effect) = string is semidet.

event_kind(eff_event(Event)) = Kind :-
    stream_kind(Event, Kind).

:- pred stream_kind(stream_event::in, string::out) is semidet.

stream_kind(se_fact_assert(_, _, _, _), "fact_assert").
stream_kind(se_fact_retract(_), "fact_retract").
stream_kind(se_fact_withdraw(_, _), "fact_retract").
stream_kind(se_fact_withdraw_unnamed(_, _), "fact_retract").
stream_kind(se_fire_begin(_), "rule_fire_begin").
stream_kind(se_fire_end(_), "rule_fire_end").
stream_kind(se_rule_lhs_facts(_, _), "rule_lhs_facts").
stream_kind(se_timer_armed(_, _, _), "timer_armed").
stream_kind(se_call_issued(_, _, _, _, _), "action_call").
stream_kind(se_emit(_, _), "action_emit").
stream_kind(se_publish(_, _, _), "action_publish").
stream_kind(se_log_emitted(_, _), "action_log").
stream_kind(se_cache_set(_, _, _), "action_cache_set").
stream_kind(se_cache_delete(_), "action_cache_delete").
stream_kind(se_clock_tick(_, _), "tick").
stream_kind(se_pump_boundary, "pump").
stream_kind(se_engine_error(Error, _), Kind) :-
    Kind = fault_class_kind(fault_class(Error)).

    % libds's four fault stream kinds, one per class ([LERR.1]).
    %
:- func fault_class_kind(fault_class) = string.

fault_class_kind(fc_computation) = "computation_error".
fault_class_kind(fc_bounds) = "bounds_error".
fault_class_kind(fc_type) = "type_error".
fault_class_kind(fc_engine) = "engine_error".

:- func compare_lists(string, list(string), list(string)) = behave_result.

compare_lists(Kind, Want, Got) = Result :-
    ( if Want = Got then
        Result = behave_result(bo_pass, Kind, "")
    else
        Result = behave_result(bo_fail, Kind,
            "want [" ++ string.join_list(", ", Want) ++ "] got ["
                ++ string.join_list(", ", Got) ++ "]")
    ).

:- func fire_name(intern_table, effect) = string is semidet.

fire_name(IT, eff_event(se_fire_begin(fire_id(_, Rule)))) = Name :-
    expand(IT, Rule, Name).

:- func log_message(effect) = string is semidet.

log_message(eff_event(se_log_emitted(_, Message))) = Message.

%-----------------------------------------------------------------------------%
% The adapter kinds
%-----------------------------------------------------------------------------%

    % `adapter_calls`, `adapter_cache_sets` and `adapter_cache_deletes`: the
    % count first, then each delivery against its expectation in order
    % ([RCTS.1.2.10]), since a rule's actions run in source order
    % ([LGRA.10.1.3], [RDSC.4a.8]).
    %
    % What pyds hands a callback is what this runtime returns as an event:
    % `se_call_issued`, `se_cache_set` and `se_cache_delete`, in delivery
    % order. So the two kinds about an unregistered callback,
    % `adapter_essential_null_cb_error` and `adapter_cache_volatile_no_cb`,
    % fail with `no_callback_kind`'s detail: they are a binding's kinds.
    %
    % A call's body is its typed arguments, compared as `runner.py` compares
    % pyds's `args` dict with the fixture's `body`: Python's equality, so key
    % order is free and `1 == 1.0`. A cache value is compared as parsed JSON
    % the same way; `value_json` is the exception, compared as text.
    %
:- type call_seen
    --->    call_seen(
                cs_service     :: string,
                cs_correlation :: maybe(string),
                cs_args        :: list(arg)
            ).

    % `no` for an empty correlation, as pyds reports `None` for one. Every
    % call carries a non-empty one ([LCRS.3.1]): a call with no `as`, or
    % whose computed `as` renders `""` ([LRST.1.2]), carries the generated
    % `__<rule>_c<N>_g<k>__`. An unevaluated correlation expression is kept,
    % spelled so that it matches no fixture.
    %
:- func delivered_call(intern_table, effect) = call_seen is semidet.

delivered_call(IT, eff_event(se_call_issued(_, Service, Corr, Args, _)))
        = call_seen(Name, CorrSeen, Args) :-
    expand(IT, Service, Name),
    (
        Corr = correlated(Ref),
        expand(IT, Ref, CorrText),
        ( if CorrText = "" then CorrSeen = no else CorrSeen = yes(CorrText) )
    ;
        Corr = correlated_expr(_),
        CorrSeen = yes("<unevaluated>")
    ).

:- func adapter_calls_result(string, json_members, intern_table, list(effect))
    = behave_result.

adapter_calls_result(Kind, Expect, IT, Effects) = Result :-
    Got = list.filter_map(delivered_call(IT), Effects),
    Want = list.filter_map(as_object, array_member(Expect, "expected_calls")),
    Result = match_deliveries(Kind, "call", call_matches, Want, Got,
        func(CS) = CS ^ cs_service ++ " "
            ++ ( if CS ^ cs_correlation = yes(C) then "'" ++ C ++ "'"
                 else "None" )
            ++ " " ++ args_text(CS ^ cs_args)).

:- pred call_matches(json_members::in, call_seen::in) is semidet.

call_matches(W, call_seen(Service, Corr, Args)) :-
    lookup_member(W, "service", j_string(Service)),
    % `runner.py`'s default when the key is absent.
    ( if lookup_member(W, "correlation", WantCorr) then
        (
            WantCorr = j_null,
            Corr = no
        ;
            WantCorr = j_string(C),
            Corr = yes(C)
        )
    else
        Corr = yes("auto")
    ),
    args_as_py(Args, Got),
    json_py_eq(j_object(object(Got)), member_or_empty(W, "body")).

    % A call's arguments as the JSON value pyds's `args` dict equals.
    %
    % A `Json` argument is a string: pyds hands it over as a `pyds.JsonText`,
    % a `str` holding the canonical text. `Bytes` and a fact equal no JSON
    % value, so a call carrying one fails here.
    %
:- pred args_as_py(list(arg)::in, assoc_list(string, json)::out) is semidet.

args_as_py([], []).
args_as_py([arg(Name, V) | As], [Name - J | Js]) :-
    arg_as_py(V, J),
    args_as_py(As, Js).

:- pred arg_as_py(arg_value::in, json::out) is semidet.

arg_as_py(av_int(I), j_int(I)).
arg_as_py(av_float(F), j_float(F)).
arg_as_py(av_string(S), j_string(S)).
arg_as_py(av_bool(B), j_bool(B)).
arg_as_py(av_json(T), j_string(T)).
arg_as_py(av_null, j_null).

    % A call's arguments for a failure line: each value as Python would
    % `repr` it, near enough to tell which argument differs.
    %
:- func args_text(list(arg)) = string.

args_text(Args) =
    "{" ++ string.join_list(", ", list.map(
        (func(arg(N, V)) = "'" ++ N ++ "': " ++ arg_value_text(V)), Args))
    ++ "}".

:- func arg_value_text(arg_value) = string.

arg_value_text(av_int(I)) = int64_to_string(I).
arg_value_text(av_float(F)) = float_to_string(F).
arg_value_text(av_string(S)) = "'" ++ S ++ "'".
arg_value_text(av_bool(B)) = ( if B = yes then "True" else "False" ).
arg_value_text(av_json(T)) = "JsonText(" ++ T ++ ")".
arg_value_text(av_bytes(_)) = "<bytes>".
arg_value_text(av_null) = "None".
arg_value_text(av_fact_ref(_)) = "<fact>".
arg_value_text(av_encoded_fact(_)) = "<EncodedFact>".

:- type set_seen
    --->    set_seen(string, string, maybe(duration)).  % key, value, ttl

:- func delivered_set(effect) = set_seen is semidet.

delivered_set(eff_event(se_cache_set(Key, Json, Ttl)))
    = set_seen(Key, Json, Ttl).

:- func cache_sets_result(string, json_members, list(effect)) = behave_result.

cache_sets_result(Kind, Expect, Effects) = Result :-
    Got = list.filter_map(delivered_set, Effects),
    Want = list.filter_map(as_object, array_member(Expect, "expected_sets")),
    ( if list.same_length(Want, Got) then
        ( if
            list.find_first_match(
                (pred(WG::in) is semidet :- WG = W - G, \+ set_matches(W, G)),
                assoc_list.from_corresponding_lists(Want, Got), WG0)
        then
            WG0 = _ - set_seen(K, J, _),
            Result = behave_result(bo_fail, Kind,
                "cache_set mismatch at key " ++ K ++ " value " ++ J)
        else
            Result = behave_result(bo_pass, Kind, "")
        )
    else
        Result = behave_result(bo_fail, Kind,
            string.format("cache_set count: want %d, got %d",
                [i(list.length(Want)), i(list.length(Got))]))
    ).

:- pred set_matches(json_members::in, set_seen::in) is semidet.

set_matches(W, set_seen(Key, Json, Ttl)) :-
    lookup_member(W, "key", j_string(Key)),
    ( if lookup_member(W, "value_json", j_string(Text)) then
        Text = Json
    else
        true
    ),
    ( if lookup_member(W, "value", Value) then
        json_text_py_eq(Json, Value)
    else
        true
    ),
    ( if lookup_member(W, "ttl_ns", j_int(WantNs)) then
        Ttl = yes(D),
        uint64.cast_to_int(duration_ns(D)) = int64.cast_to_int(WantNs)
    else
        true
    ).

:- func cache_deleted(effect) = string is semidet.

cache_deleted(eff_event(se_cache_delete(Key))) = Key.

    % `adapter_calls`'s shape: the count, then each delivery against its
    % expectation in order. `Show` renders a delivery for the failure detail.
    %
:- func match_deliveries(string, string, pred(json_members, T),
    list(json_members), list(T), func(T) = string) = behave_result.
:- mode match_deliveries(in, in, in(pred(in, in) is semidet), in, in,
    in) = out is det.

match_deliveries(Kind, What, Matches, Want, Got, Show) = Result :-
    GotText = "[" ++ string.join_list("; ", list.map(Show, Got)) ++ "]",
    ( if \+ list.same_length(Want, Got) then
        Result = behave_result(bo_fail, Kind,
            string.format("%s count: want %d, got %d %s",
                [s(What), i(list.length(Want)), i(list.length(Got)),
                 s(GotText)]))
    else if ordered_match(Matches, Want, Got) then
        Result = behave_result(bo_pass, Kind, "")
    else
        Result = behave_result(bo_fail, Kind,
            "ordered: a " ++ What ++ " differs from its expectation in "
                ++ GotText)
    ).

:- pred ordered_match(pred(json_members, T)::in(pred(in, in) is semidet),
    list(json_members)::in, list(T)::in) is semidet.

ordered_match(_, [], []).
ordered_match(Matches, [W | Ws], [G | Gs]) :-
    Matches(W, G),
    ordered_match(Matches, Ws, Gs).

:- func as_object(json) = json_members is semidet.

as_object(j_object(Ms)) = Ms.

:- func member_or_empty(json_members, string) = json.

member_or_empty(Ms, Key) =
    ( if lookup_member(Ms, Key, J) then J else j_object(empty_object) ).

    % JSON text the runtime produced, parsed, against an expectation, under
    % Python's `==`.
    %
:- pred json_text_py_eq(string::in, json::in) is semidet.

json_text_py_eq(Text, Want) :-
    parse_json(Text, json_ok(Got)),
    json_py_eq(Got, Want).

    % Python's `==` over decoded JSON: numbers compare by value across Int and
    % Float (`1 == 1.0`), objects by key regardless of order (members are
    % sorted on construction), arrays element-wise.
    %
:- pred json_py_eq(json::in, json::in) is semidet.

json_py_eq(A, B) :-
    ( if A = j_int(I), B = j_int(J) then
        I = J
    else if json_number(A, FA), json_number(B, FB) then
        FA = FB
    else if A = j_array(As), B = j_array(Bs) then
        all_json_py_eq(As, Bs)
    else if A = j_object(OA), B = j_object(OB) then
        members_json_py_eq(members(OA), members(OB))
    else
        A = B
    ).

:- pred json_number(json::in, float::out) is semidet.

json_number(j_int(I), float.cast_from_int64(I)).
json_number(j_float(F), F).

:- pred all_json_py_eq(list(json)::in, list(json)::in) is semidet.

all_json_py_eq([], []).
all_json_py_eq([A | As], [B | Bs]) :-
    json_py_eq(A, B),
    all_json_py_eq(As, Bs).

:- pred members_json_py_eq(assoc_list(string, json)::in,
    assoc_list(string, json)::in) is semidet.

members_json_py_eq([], []).
members_json_py_eq([KA - VA | As], [KB - VB | Bs]) :-
    KA = KB,
    json_py_eq(VA, VB),
    members_json_py_eq(As, Bs).

%-----------------------------------------------------------------------------%
% The cross-tier kinds
%-----------------------------------------------------------------------------%

    % `cross_tier_fact_counts` and `cross_tier_per_engine_event_counts`: one
    % engine per `expect.engines` entry, each compiled from its own `rules_ds`
    % and started as every fixture engine is (`fixture_engine`, the clock at
    % 0); the steps routed by their `engine`; then each named engine's live
    % fact count against `engine_fact_counts_after`, or its count of each
    % named event kind against `expected_event_counts`. The first mismatch is
    % the detail.
    %
    % No state is shared between the engines but what `forward` carries
    % ([IARC.1.11], [IDAT.5.5]).
    %
:- pred cross_tier_kind(string::in) is semidet.

cross_tier_kind("cross_tier_fact_counts").
cross_tier_kind("cross_tier_per_engine_event_counts").

    % One engine of a cross-tier fixture, and what it has done.
    %
:- type tier_run
    --->    tier_run(
                tr_program   :: program,
                tr_engine    :: engine,
                tr_handles   :: map(string, fact_id),
                tr_rev       :: list(stamped),       % newest first
                tr_published :: list(maybe(json)),
                    % Every fact this engine published, in publication order,
                    % as the `assert` step that carries it to another engine;
                    % `no` where `external_step` cannot write one, which stops
                    % a `forward` that reaches it.
                tr_external  :: list(maybe(list(uint8))),
                    % The same publications as the FactExternal each
                    % `se_publish` carried ([RFCS.23.1]), encoded; `no` where
                    % it carried none, or it does not encode.
                tr_published_at :: list(maybe(maybe(int64))),
                    % The same publications as the `asserted_at` each one's
                    % FactExternal carried ([RFCS.23.5]), `no` inside where
                    % it carried none; `no` where there was no record. For
                    % [RCTS.1.2.29]'s `expected_published_asserted_at`.
                tr_forwarded :: map(string, int),
                    % Per source engine, how many of its publications a
                    % `forward` has already carried here.
                tr_forwarded_external :: map(string, int)
                    % The same for `forward_external`, counted apart.
            ).

:- type xt_built(T)
    --->    xt_built(T)
    ;       xt_not_built(behave_result).

:- type xt_status
    --->    xt_ok
    ;       xt_failed(string)
            % An unknown engine, or a refused host call.
    ;       xt_unsupported(string).

:- func run_cross_tier(registry, string, maybe(library_sources), json_members)
    = behave_result.

run_cross_tier(Registry, Kind, Libraries, Expect) = Result :-
    ( if
        lookup_member(Expect, "engines", EnginesJ),
        EnginesJ = j_object(EnginesObj),
        Decls = members(EnginesObj),
        Decls = [_ | _]
    then
        build_tiers(Registry, Kind, Libraries, Decls, map.init, Built),
        (
            Built = xt_not_built(Failed),
            Result = Failed
        ;
            Built = xt_built(Tiers0),
            run_tier_steps(array_member(Expect, "steps"), Tiers0, Tiers,
                [], RevStatuses, Status),
            (
                Status = xt_ok,
                % [RCTS.1.2.30]'s pump statuses, then [RCTS.1.2.29]'s
                % published `asserted_at`, then the kind's own expectation,
                % the first that fails being the result, as in `runner.py`.
                Result = pump_statuses_result(Kind, Expect,
                    list.reverse(RevStatuses),
                    published_at_result(Kind, Expect, Tiers,
                        judge_tiers(Kind, Expect, Tiers)))
            ;
                Status = xt_failed(Why),
                Result = behave_result(bo_fail, Kind, Why)
            ;
                Status = xt_unsupported(Why),
                Result = behave_result(bo_unsupported, Kind, Why)
            )
        )
    else
        Result = behave_result(bo_fail, Kind,
            "cross-tier test missing `expect.engines` mapping")
    ).

    % Each engine's program, compiled as `classify` compiles a fixture's, and
    % its engine. The first that does not compile or load is the fixture's
    % outcome, named for its engine.
    %
:- pred build_tiers(registry::in, string::in, maybe(library_sources)::in,
                    assoc_list(string, json)::in, map(string, tier_run)::in,
                    xt_built(map(string, tier_run))::out) is det.

build_tiers(_, _, _, [], Tiers, xt_built(Tiers)).
build_tiers(Registry, Kind, Libraries, [Label - DeclJ | Decls], Tiers0,
        Built) :-
    ( if
        DeclJ = j_object(Decl),
        lookup_member(Decl, "rules_ds", SourceJ),
        SourceJ = j_string(Source)
    then
        compile_labelled_in(Registry, as_though("default"),
            Libraries, dsrt_absent, in_memory_labels,
            Source, Compiled),
        ProgramBuilt = build_program(Kind, Compiled),
        (
            ProgramBuilt = xt_not_built(behave_result(O, K, D)),
            Built = xt_not_built(
                behave_result(O, K, "engine `" ++ Label ++ "`: " ++ D))
        ;
            ProgramBuilt = xt_built(P),
            % [RCTS.1.2.29]: an engine declared with `"wall_clock": "unset"`
            % keeps its mock wall clock unset until a `wall_set` step gives it
            % one, as `steps_engine` leaves a logical fixture's.
            ( if lookup_member(Decl, "wall_clock", j_string("unset")) then
                engine_use_mock_clock(init_engine(P), E0)
            else
                E0 = fixture_engine(P)
            ),
            set_clock(from_ns(0u64), _, E0, E),
            map.set(Label,
                tier_run(P, E, map.init, [], [], [], [], map.init, map.init),
                Tiers0, Tiers1),
            build_tiers(Registry, Kind, Libraries, Decls, Tiers1, Built)
        )
    else
        Built = xt_not_built(behave_result(bo_fail, Kind,
            "engine `" ++ Label ++ "` has no `rules_ds`"))
    ).

    % A compile's program, or the outcome `judge` gives a fixture whose
    % compile or load did not produce one.
    %
:- func build_program(string, compile_result) = xt_built(program).

build_program(Kind, Compiled) = Built :-
    ( if Compiled = compiled(Bytes, _, _) then
        load_dsc(from_bytes(Bytes), Load),
        (
            Load = loaded(P),
            Built = xt_built(P)
        ;
            Load = load_failed(Error),
            Built = xt_not_built(
                behave_result(bo_load_failed, Kind, string.string(Error)))
        )
    else
        Built = xt_not_built(judge(Kind, empty_object, Compiled))
    ).

    % The steps in order, noting the status each `pump` step reports, on
    % whichever engine it names (`pump_status_code`), newest first, for
    % [RCTS.1.2.30]'s `expected_pump_statuses`.
    %
:- pred run_tier_steps(list(json)::in,
                       map(string, tier_run)::in, map(string, tier_run)::out,
                       list(int)::in, list(int)::out,
                       xt_status::out) is det.

run_tier_steps([], !Tiers, !RevStatuses, xt_ok).
run_tier_steps([Step | Steps], !Tiers, !RevStatuses, Status) :-
    run_tier_step(Step, !Tiers, !RevStatuses, StepStatus),
    (
        StepStatus = xt_ok,
        run_tier_steps(Steps, !Tiers, !RevStatuses, Status)
    ;
        ( StepStatus = xt_failed(_)
        ; StepStatus = xt_unsupported(_)
        ),
        Status = StepStatus
    ).

    % One step, on the engine its `engine` names. Every op but `forward` and
    % `forward_external` (`receive_on_tier`) is `run_step`'s, exactly as a
    % single-engine fixture runs it.
    %
    % `forward` is [NCBK.10.1]'s integrator bridge: every fact the `from`
    % engine published since the last `forward` from it to this one is
    % asserted here as an `assert` step, under its schema name and slot
    % values, in publication order. The receiving engine's own schema decides
    % what it is.
    %
:- pred run_tier_step(json::in,
                      map(string, tier_run)::in, map(string, tier_run)::out,
                      list(int)::in, list(int)::out,
                      xt_status::out) is det.

run_tier_step(Step, !Tiers, !RevStatuses, Status) :-
    ( if
        Step = j_object(Ms),
        lookup_member(Ms, "engine", LabelJ),
        LabelJ = j_string(Label)
    then
        ( if map.search(!.Tiers, Label, T0) then
            ( if lookup_member(Ms, "op", j_string("forward")) then
                ( if
                    lookup_member(Ms, "from", FromJ),
                    FromJ = j_string(From),
                    map.search(!.Tiers, From, Src)
                then
                    Published = Src ^ tr_published,
                    Start = ( if map.search(T0 ^ tr_forwarded, From, S)
                              then S else 0 ),
                    ( if list.drop(Start, Published, Rest) then
                        Pending = Rest
                    else
                        Pending = []
                    ),
                    ( if carried_steps(Pending, PendingSteps) then
                        run_on_tier(PendingSteps, T0, T1, Status),
                        T = T1 ^ tr_forwarded :=
                            map.set(T1 ^ tr_forwarded, From,
                                list.length(Published)),
                        map.set(Label, T, !Tiers)
                    else
                        Status = xt_unsupported("forward: a published fact "
                            ++ "this driver cannot carry to another engine")
                    )
                else
                    Status = xt_failed("forward: unknown source engine `"
                        ++ ( if lookup_member(Ms, "from", j_string(F))
                             then F else "" ) ++ "`")
                )
            else if lookup_member(Ms, "op", j_string("forward_external")) then
                ( if
                    lookup_member(Ms, "from", XFromJ),
                    XFromJ = j_string(XFrom),
                    map.search(!.Tiers, XFrom, XSrc)
                then
                    External = XSrc ^ tr_external,
                    XStart = ( if map.search(T0 ^ tr_forwarded_external,
                                    XFrom, XS)
                               then XS else 0 ),
                    ( if list.drop(XStart, External, XRest) then
                        XPending = XRest
                    else
                        XPending = []
                    ),
                    receive_on_tier(XPending, T0, XT1, Status),
                    XT = XT1 ^ tr_forwarded_external :=
                        map.set(XT1 ^ tr_forwarded_external, XFrom,
                            list.length(External)),
                    map.set(Label, XT, !Tiers)
                else
                    Status = xt_failed("forward_external: unknown source "
                        ++ "engine `"
                        ++ ( if lookup_member(Ms, "from", j_string(XF))
                             then XF else "" ) ++ "`")
                )
            else
                run_on_tier([Step], T0, T, Status),
                ( if pump_step(Step) then
                    list.take_upto(list.length(T ^ tr_rev)
                        - list.length(T0 ^ tr_rev), T ^ tr_rev, Pushed),
                    !:RevStatuses = [pump_status_code(list.condense(
                        list.map(stamped_effects, Pushed))) | !.RevStatuses]
                else
                    true
                ),
                map.set(Label, T, !Tiers)
            )
        else
            Status = xt_failed("step targets unknown engine `" ++ Label
                ++ "`")
        )
    else
        Status = xt_unsupported("a cross-tier step with no `engine`")
    ).

    % The `assert` steps of a `forward`'s publications; fails if one has none.
    %
:- pred carried_steps(list(maybe(json))::in, list(json)::out) is semidet.

carried_steps([], []).
carried_steps([yes(Step) | Pending], [Step | Steps]) :-
    carried_steps(Pending, Steps).

    % `forward_external`: each publication's FactExternal ([RFCS.23.1])
    % handed to this engine's `assert_external` ([NCBK.10.4]), in publication
    % order. Only the record crosses ([RFCS.23.6]: no TTL). A publication that
    % carried no record stops the fixture as `unsupported`; a record the
    % engine refuses, or asserts only part of, fails it.
    %
:- pred receive_on_tier(list(maybe(list(uint8)))::in, tier_run::in,
                        tier_run::out, xt_status::out) is det.

receive_on_tier([], !T, xt_ok).
receive_on_tier([MaybeBytes | Rest], T0, T, Status) :-
    (
        MaybeBytes = no,
        T = T0,
        Status = xt_unsupported("forward_external: a publication that "
            ++ "carried no FactExternal")
    ;
        MaybeBytes = yes(Bytes),
        T0 = tier_run(P, E0, H, Rev0, Pub0, Ext0, At0, Fwd, FwdX),
        assert_external(from_bytes(Bytes), Received, Effects, E0, E),
        Rev = [{engine_now(E), Effects} | Rev0],
        capture_publishes(Effects, Pub0, Pub, Ext0, Ext, At0, At),
        T1 = tier_run(P, E, H, Rev, Pub, Ext, At, Fwd, FwdX),
        ( if Received = ext_asserted then
            receive_on_tier(Rest, T1, T, Status)
        else
            T = T1,
            Status = xt_failed("forward_external: the record was not "
                ++ "asserted: " ++ string.string(Received))
        )
    ).

    % Steps on one engine, each step's publications captured as it ends.
    %
:- pred run_on_tier(list(json)::in, tier_run::in, tier_run::out,
                    xt_status::out) is det.

run_on_tier([], !T, xt_ok).
run_on_tier([Step | Steps], T0, T, Status) :-
    T0 = tier_run(P, E0, H0, Rev0, Pub0, Ext0, At0, Fwd, FwdX),
    run_step(P, Step, StepStatus, E0, E, H0, H, Rev0, Rev),
    list.take_upto(list.length(Rev) - list.length(Rev0), Rev, Pushed),
    NewEffects = list.condense(list.map(stamped_effects,
        list.reverse(Pushed))),
    capture_publishes(NewEffects, Pub0, Pub, Ext0, Ext, At0, At),
    T1 = tier_run(P, E, H, Rev, Pub, Ext, At, Fwd, FwdX),
    (
        StepStatus = run_ok,
        run_on_tier(Steps, T1, T, Status)
    ;
        StepStatus = run_unsupported(Why),
        T = T1,
        Status = xt_unsupported(Why)
    ;
        StepStatus = run_refused(Refusal),
        T = T1,
        Status = xt_failed(refusal_text(Refusal))
    ).

    % Each `se_publish` in one step's effects, as the `assert` step that
    % carries it.
    %
    % The name and the values are the publish event's, never working
    % memory's ([RCTS.1.2.29], [LTIE.4.3]): the step is the event's
    % FactExternal's schema name and fields (`external_step`). A publication
    % with no record, or a value `external_json` cannot write, is `no`, which
    % stops a `forward` that reaches it as `unsupported`; `forward_external`
    % carries the record instead ([RFCS.23.7]).
    %
    % Each publication's FactExternal goes to `!Ext` alongside, encoded, and
    % its `asserted_at` to `!At`.
    %
:- pred capture_publishes(list(effect)::in,
                          list(maybe(json))::in, list(maybe(json))::out,
                          list(maybe(list(uint8)))::in,
                          list(maybe(list(uint8)))::out,
                          list(maybe(maybe(int64)))::in,
                          list(maybe(maybe(int64)))::out) is det.

capture_publishes([], !Pub, !Ext, !At).
capture_publishes([Eff | Effs], !Pub, !Ext, !At) :-
    ( if Eff = eff_event(se_publish(_, _, MaybeFE)) then
        (
            MaybeFE = yes(AtFE),
            !:At = !.At ++ [yes(AtFE ^ fe_asserted_at)]
        ;
            MaybeFE = no,
            !:At = !.At ++ [no]
        ),
        ( if
            MaybeFE = yes(FE0),
            external_step(FE0, Step)
        then
            !:Pub = !.Pub ++ [yes(Step)]
        else
            !:Pub = !.Pub ++ [no]
        ),
        ( if
            MaybeFE = yes(FE),
            encode_fact_external(FE, Encoded)
        then
            !:Ext = !.Ext ++ [yes(Encoded)]
        else
            !:Ext = !.Ext ++ [no]
        ),
        capture_publishes(Effs, !Pub, !Ext, !At)
    else
        capture_publishes(Effs, !Pub, !Ext, !At)
    ).

    % A FactExternal as the `assert` step that carries it: its schema's name,
    % and each field as a slot.
    %
:- pred external_step(fact_external::in, json::out) is semidet.

external_step(FE, Step) :-
    list.map(external_slot, FE ^ fe_fields, Slots),
    Step = j_object(object([
        "op" - j_string("assert"),
        "schema" - j_string(FE ^ fe_schema),
        "slots" - j_object(object(Slots))
    ])).

:- pred external_slot(ds.fact_external.arg::in, pair(string, json)::out)
    is semidet.

external_slot(arg(Name, V), Name - J) :-
    external_json(V, J).

    % A field's value as the JSON a step writes it in, so `slot_value` reads it
    % back as the same value; a `Time`, `Date` or `Duration` crosses as its
    % integer ([RFCS.23.2]). A `Bytes` or a fact reference has no arm, so a
    % publication carrying one stops a `forward` (`capture_publishes`).
    %
:- pred external_json(ds.fact_external.arg_value::in, json::out) is semidet.

external_json(av_int(I), j_int(I)).
external_json(av_float(F), j_float(F)).
external_json(av_bool(B), j_bool(B)).
external_json(av_string(S), j_string(S)).
external_json(av_json(Text), J) :-
    parse_json(Text, json_ok(J)).
external_json(av_null, j_null).

    % [RCTS.1.2.29]'s `expected_published_asserted_at`, judged over each
    % engine's publications; `Result0` when the fixture carries none or it
    % holds. `rcts_1_2_29_published_at_refusal` has already refused a field
    % of another shape.
    %
:- func published_at_result(string, json_members, map(string, tier_run),
    behave_result) = behave_result.

published_at_result(Kind, Expect, Tiers, Result0) = Result :-
    ( if
        lookup_member(Expect, "expected_published_asserted_at", J),
        published_at_shape(J, Want),
        published_at_failure(Want, map.map_values_only(
            (func(T) = T ^ tr_published_at), Tiers)) = yes(Why)
    then
        Result = behave_result(bo_fail, Kind, Why)
    else
        Result = Result0
    ).

    % For each engine `Want` names, the `asserted_at` each of its
    % publications carried, in publication order, against its entries; the
    % first that differs, or a publication with no record, is the failure.
    % `runner.py`'s `_published_asserted_at_mismatch` judges libds's alike.
    %
:- func published_at_failure(assoc_list(string, list(maybe(int64))),
    map(string, list(maybe(maybe(int64))))) = maybe(string).

published_at_failure([], _) = no.
published_at_failure([Label - WantAt | Rest], Got) = Failure :-
    ( if map.search(Got, Label, Rs) then Records = Rs else Records = [] ),
    ( if records_asserted_at(Records, GotAt) then
        ( if GotAt = WantAt then
            Failure = published_at_failure(Rest, Got)
        else
            Failure = yes("engine `" ++ Label
                ++ "` published asserted_at: want " ++ at_list_text(WantAt)
                ++ ", got " ++ at_list_text(GotAt))
        )
    else
        Failure = yes("engine `" ++ Label ++ "`'s publication carried no "
            ++ "FactExternal ([RCTS.1.2.29])")
    ).

:- pred records_asserted_at(list(maybe(maybe(int64)))::in,
    list(maybe(int64))::out) is semidet.

records_asserted_at([], []).
records_asserted_at([yes(At) | Rs], [At | Ats]) :-
    records_asserted_at(Rs, Ats).

:- func at_list_text(list(maybe(int64))) = string.

at_list_text(Ats) =
    "[" ++ string.join_list(", ", list.map(at_text, Ats)) ++ "]".

:- func at_text(maybe(int64)) = string.

at_text(yes(N)) = int64_to_string(N).
at_text(no) = "null".

:- func judge_tiers(string, json_members, map(string, tier_run))
    = behave_result.

judge_tiers(Kind, Expect, Tiers) = Result :-
    ( if Kind = "cross_tier_per_engine_event_counts" then
        Field = "expected_event_counts"
    else
        Field = "engine_fact_counts_after"
    ),
    ( if lookup_member(Expect, Field, WantJ), WantJ = j_object(Want) then
        ( if Kind = "cross_tier_per_engine_event_counts" then
            Failure = first_event_count_failure(Tiers, members(Want))
        else
            Failure = first_fact_count_failure(Tiers, members(Want))
        ),
        (
            Failure = no,
            Result = behave_result(bo_pass, Kind, "")
        ;
            Failure = yes(Why),
            Result = behave_result(bo_fail, Kind, Why)
        )
    else
        Result = behave_result(bo_fail, Kind, "no `" ++ Field ++ "` object")
    ).

    % An engine the expectation names and the fixture does not declare fails
    % a fact count, and has no events for an event count, as in `runner.py`.
    %
:- func first_fact_count_failure(map(string, tier_run),
    assoc_list(string, json)) = maybe(string).

first_fact_count_failure(_, []) = no.
first_fact_count_failure(Tiers, [Label - WantJ | Rest]) = Failure :-
    ( if map.search(Tiers, Label, T) then
        Got = engine_fact_count(T ^ tr_engine),
        ( if WantJ = j_int(Want), int64.cast_to_int(Want) = Got then
            Failure = first_fact_count_failure(Tiers, Rest)
        else
            Failure = yes(string.format("engine `%s` fact_count: want %s, got %d",
                [s(Label), s(want_text(WantJ)), i(Got)]))
        )
    else
        Failure = yes("engine_fact_counts_after references unknown engine `"
            ++ Label ++ "`")
    ).

:- func first_event_count_failure(map(string, tier_run),
    assoc_list(string, json)) = maybe(string).

first_event_count_failure(_, []) = no.
first_event_count_failure(Tiers, [Label - WantJ | Rest]) = Failure :-
    ( if WantJ = j_object(WantKinds) then
        ( if map.search(Tiers, Label, T) then
            Kinds = list.filter_map(event_kind, list.condense(
                list.map(stamped_effects, list.reverse(T ^ tr_rev))))
        else
            Kinds = []
        ),
        Here = first_kind_count_failure(Label, Kinds, members(WantKinds)),
        (
            Here = yes(_),
            Failure = Here
        ;
            Here = no,
            Failure = first_event_count_failure(Tiers, Rest)
        )
    else
        Failure = yes("expected_event_counts for engine `" ++ Label
            ++ "` is not an object")
    ).

:- func first_kind_count_failure(string, list(string),
    assoc_list(string, json)) = maybe(string).

first_kind_count_failure(_, _, []) = no.
first_kind_count_failure(Label, Kinds, [Kind - WantJ | Rest]) = Failure :-
    Got = list.length(list.filter((pred(K::in) is semidet :- K = Kind),
        Kinds)),
    ( if WantJ = j_int(Want), int64.cast_to_int(Want) = Got then
        Failure = first_kind_count_failure(Label, Kinds, Rest)
    else
        Failure = yes(string.format(
            "engine `%s` event `%s` count: want %s, got %d",
            [s(Label), s(Kind), s(want_text(WantJ)), i(Got)]))
    ).

:- func want_text(json) = string.

want_text(J) =
    ( if J = j_int(N) then string.int_to_string(int64.cast_to_int(N))
    else "a non-integer" ).

%-----------------------------------------------------------------------------%

    % `runtime_error`: after `asserts` and an optional pump, some call must
    % have faulted, with `code` (the `DS_ERR_*` integer as a string) and any
    % `message_contains` in its message.
    %
    % This runtime has no error messages or status codes: a refused assert is
    % an `se_engine_error` event carrying the typed reason, which the driver
    % maps onto `libds.h`'s code and libds's status text for that code. The
    % code is the check that means something; the text lets
    % `message_contains` read something. A fault with no row here fails the
    % fixture, naming itself.
    %
:- func run_runtime_error(json_members, program) = behave_result.

run_runtime_error(Expect, P) = Result :-
    Kind = "runtime_error",
    E0 = with_cache_cap(Expect, fixture_engine(P)),
    Seeds = list.map(seed_step, array_member(Expect, "cache_seeds")),
    % `steps`, when present, is the whole input, for a refusal that needs the
    % clock to move between inputs.
    ( if lookup_member(Expect, "steps", _) then
        Steps = array_member(Expect, "steps")
    else
        Asserts = list.map(assert_step, array_member(Expect, "asserts")),
        ( if lookup_member(Expect, "pump", PumpJ), PumpJ = j_bool(yes) then
            Pump = [j_object(object(["op" - j_string("pump")]))]
        else
            Pump = []
        ),
        Steps = Asserts ++ Pump
    ),
    % The seeds are arrange, not inputs, so they run first and `fault_at`
    % does not count them. A refused seed is the fault at no input.
    run_steps(P, Seeds, E0, E1, map.init, Handles1, [], RevSeeded,
        SeedStatus),
    ( if SeedStatus = run_ok then
        run_steps_faulting(P, Steps, 0, no, FaultAt, E1, E, Handles1, _,
            RevSeeded, RevEffects, Status)
    else
        FaultAt = no,
        E = E1,
        RevEffects = RevSeeded,
        Status = SeedStatus
    ),
    Effects = list.condense(list.map(stamped_effects,
        list.reverse(RevEffects))),
    (
        Status = run_unsupported(Why),
        Result = behave_result(bo_unsupported, Kind, Why)
    ;
        Status = run_refused(Refusal),
        (
            Refusal = refused_status(Code, Text),
            Result = silent_refusal_result(Kind, Expect, FaultAt, Effects, E,
                Code, Text)
        ;
            % The refusal ended the steps; its fault is in `Effects`.
            Refusal = refused(_),
            Result = event_fault_result(Kind, Expect, FaultAt, Effects, E)
        )
    ;
        Status = run_ok,
        Result = event_fault_result(Kind, Expect, FaultAt, Effects, E)
    ).

    % `fault_at`: the 0-based index of the input that must raise the fault,
    % into `steps`, or into `asserts` with the pump after them. Without it, a
    % fault from any input passes. Fails when the fixture names no
    % `fault_at`, or when the fault came where it says.
    %
:- func fault_at_mismatch(json_members, maybe(int)) = string is semidet.

fault_at_mismatch(Expect, FaultAt) = Why :-
    int_member(Expect, "fault_at", WantAt),
    FaultAt \= yes(WantAt),
    Why = string.format("runtime_error: want the fault at input %d, "
        ++ "it came at %s", [i(WantAt), s(
            ( if FaultAt = yes(Got) then
                "input " ++ string.int_to_string(Got)
            else
                "no input" ))]).

    % A refusal with no event, judged on its status. With `no_fault_events`,
    % the stream must also carry no engine error of any kind ([LGRA.5.8.6]'s
    % host refusal). `fault_at` first; then the checks `event_fault_result`
    % makes.
    %
:- func silent_refusal_result(string, json_members, maybe(int), list(effect),
    engine, int, string) = behave_result.

silent_refusal_result(Kind, Expect, FaultAt, Effects, E, Code, Text) = Result :-
    ( if fault_at_mismatch(Expect, FaultAt) = Why then
        Result = behave_result(bo_fail, Kind, Why)
    else if
        lookup_member(Expect, "code", CodeJ),
        CodeJ = j_string(WantCode)
    then
        WantText = string.string(message_wants(Expect)),
        ( if
            string.int_to_string(Code) = WantCode,
            contains_all(Text, message_wants(Expect))
        then
            ( if
                lookup_member(Expect, "no_fault_events", NJ),
                NJ = j_bool(yes),
                list.filter_map(engine_error_of, Effects) = [Err | _]
            then
                Result = behave_result(bo_fail, Kind,
                    "runtime_error: refused as expected, but the stream "
                        ++ "carries a fault: " ++ string.string(Err))
            else if fault_events_mismatch(Expect, Effects) = Why then
                Result = behave_result(bo_fail, Kind, Why)
            else if last_event_mismatch(Expect, Effects) = Why then
                Result = behave_result(bo_fail, Kind, Why)
            else if fact_count_mismatch(Expect, E) = Why then
                Result = behave_result(bo_fail, Kind, Why)
            else if halted_fault_mismatch(Expect, E) = Why then
                Result = behave_result(bo_fail, Kind, Why)
            else
                Result = behave_result(bo_pass, Kind, "")
            )
        else
            Result = behave_result(bo_fail, Kind,
                string.format("runtime_error: want code %s containing %s, "
                    ++ "got %s", [s(WantCode), s(WantText),
                    s(refused_text(Code, Text))]))
        )
    else
        Result = behave_result(bo_unsupported, Kind, "no string `code`")
    ).

    % A fault the run recorded as an `se_engine_error`, mapped onto libds's
    % code and status text (`libds_status`): after `fault_at`, the first
    % fault's code and message, then `fault_events`, `last_event`,
    % `fact_count_after` and `halted_fault`.
    %
:- func event_fault_result(string, json_members, maybe(int), list(effect),
    engine) = behave_result.

event_fault_result(Kind, Expect, FaultAt, Effects, E) = Result :-
    ( if fault_at_mismatch(Expect, FaultAt) = Why then
        Result = behave_result(bo_fail, Kind, Why)
    else if
        lookup_member(Expect, "code", CodeJ),
        CodeJ = j_string(WantCode)
    then
        WantText = string.string(message_wants(Expect)),
        Errors = list.filter_map(engine_error_of, Effects),
        (
            Errors = [],
            Result = behave_result(bo_fail, Kind,
                "runtime_error: expected a fault (code " ++ WantCode
                    ++ "), none raised")
        ;
            Errors = [First | _],
            ( if libds_status(First, Code, Text) then
                ( if
                    string.int_to_string(Code) = WantCode,
                    contains_all(Text, message_wants(Expect))
                then
                    ( if fault_events_mismatch(Expect, Effects) = Why then
                        Result = behave_result(bo_fail, Kind, Why)
                    else if last_event_mismatch(Expect, Effects) = Why then
                        Result = behave_result(bo_fail, Kind, Why)
                    else if fact_count_mismatch(Expect, E) = Why then
                        Result = behave_result(bo_fail, Kind, Why)
                    else if halted_fault_mismatch(Expect, E) = Why then
                        Result = behave_result(bo_fail, Kind, Why)
                    else
                        Result = behave_result(bo_pass, Kind, "")
                    )
                else
                    Result = behave_result(bo_fail, Kind,
                        string.format("runtime_error: want code %s "
                            ++ "containing %s, got [%d] %s",
                            [s(WantCode), s(WantText), i(Code), s(Text)]))
                )
            else
                Result = behave_result(bo_fail, Kind,
                    "runtime_error: a fault with no libds status mapped: "
                        ++ string.string(First))
            )
        )
    else
        Result = behave_result(bo_unsupported, Kind, "no string `code`")
    ).

    % What a `cache_seed` step did, as pyds's `cache_seed` reports it. A Json
    % value over a limit is the refusal with no event ([LGRA.5.8.6]), and a
    % seed after the engine's first stream event is DS_ERR_STATE
    % ([NLFC.9.2]); either fails a fixture that does not pin it
    % ([RCTS.1.2.28]). An outcome with no libds status here stops the fixture
    % as unsupported.
    %
:- func seed_status(seed_result) = run_status.

seed_status(seeded) = run_ok.
seed_status(seed_json_limit(Breach)) =
    run_refused(refused_status(-221, json_limit_message(Breach ^ jb_limit))).
seed_status(seed_text_refused(Why)) = Status :-
    ( if Why = ds.json_text.jr_int_outside_int64 then
        % [LGRA.5.8.9]: DS_ERR_PARSE, with libds's text (json.c
        % `parse_number`).
        Status = run_refused(refused_status(-100,
            "JSON integer literal outside int64"))
    else if Why = ds.json_text.jr_float_outside_double then
        % [LGRA.5.8.10]: DS_ERR_PARSE, with libds's text for a float
        % literal that rounds to an infinity (json.c `parse_number`).
        Status = run_refused(refused_status(-100,
            "JSON float literal outside the double range"))
    else if Why = ds.json_text.jr_unpaired_surrogate then
        % [LSTR.7.2.3]: DS_ERR_PARSE, with libds's text for a
        % surrogate escape that is half of no pair (json.c
        % `UNPAIRED_SURROGATE`).
        Status = run_refused(refused_status(-100,
            "JSON string has a surrogate escape that is half of no pair "
                ++ "(LSTR.7.2.3)"))
    else
        Status = run_unsupported("a cache seed whose text is not one JSON "
            ++ "value: " ++ string.string(Why))
    ).
seed_status(seed_after_pump) =
    run_refused(refused_status(-4,
        "a cache seed after the engine's first stream event is refused "
            ++ "([NLFC.9.2])")).
seed_status(seed_halted(_)) =
    run_unsupported("a cache seed on a halted engine").
seed_status(seed_nonfinite) =
    run_unsupported("a cache seed of a non-finite Float").
seed_status(seed_capped(_)) =
    run_unsupported("a cache seed over a cache cap").
seed_status(seed_time_range) =
    run_refused(refused_status(-205,
        "a cache seed's TTL is longer than the Time range ([NLFC.9.5])")).
seed_status(seed_encoding) =
    % [LSTR.8.5]: DS_ERR_ENCODING, refused by pyds's `ds_json_parse` (the
    % text) or by `ds_engine_cache_seed` (the key), with no event.
    run_refused(refused_status(-222,
        "a cache seed's text is not well-formed UTF-8 ([LSTR.8.5])")).

    % A Json limit's refusal, naming the limit as libds's `DS_JSON_MAX_*`
    % does, so a fixture's `message_contains` can tell the four apart.
    %
:- func json_limit_message(json_limit) = string.

json_limit_message(jl_text_bytes) =
    "JSON text longer than DS_JSON_MAX_TEXT_BYTES".
json_limit_message(jl_depth) = "Json value over DS_JSON_MAX_DEPTH".
json_limit_message(jl_nodes) = "Json value over DS_JSON_MAX_NODES".
json_limit_message(jl_string_bytes) =
    "Json value over DS_JSON_MAX_STRING_BYTES".

    % A Json value as Python's `json.dumps` writes it by default, as
    % `runner.py` hands a seed to pyds: `", "` between items,
    % `": "` after a key, and every character outside U+0020..U+007E escaped
    % (`ensure_ascii`): `\"`, `\\`, `\n`, `\r`, `\t`, `\b` and `\f`, and
    % `\u` with four lower-case hex digits for the rest, a surrogate pair
    % past U+FFFF.
    %
    % `no` for a Float: Python writes its `repr`, which this does not
    % reproduce.
    %
    % An object's members come in key order (`ds.json` sorts them), where
    % Python keeps the fixture's. The bytes are the same in number, and the
    % number is all the text limit reads.
    %
:- func python_json_dumps(json) = maybe(string).

python_json_dumps(j_null) = yes("null").
python_json_dumps(j_bool(B)) = yes(( if B = yes then "true" else "false" )).
python_json_dumps(j_int(I)) = yes(string.int64_to_string(I)).
python_json_dumps(j_float(_)) = no.
python_json_dumps(j_string(S)) = yes(python_json_string(S)).
python_json_dumps(j_array(Es)) = Text :-
    ( if python_json_all(Es, Items) then
        Text = yes("[" ++ string.join_list(", ", Items) ++ "]")
    else
        Text = no
    ).
python_json_dumps(j_object(M)) = Text :-
    ( if python_json_members(members(M), Items) then
        Text = yes("{" ++ string.join_list(", ", Items) ++ "}")
    else
        Text = no
    ).

:- pred python_json_all(list(json)::in, list(string)::out) is semidet.

python_json_all([], []).
python_json_all([E | Es], [T | Ts]) :-
    python_json_dumps(E) = yes(T),
    python_json_all(Es, Ts).

:- pred python_json_members(assoc_list(string, json)::in, list(string)::out)
    is semidet.

python_json_members([], []).
python_json_members([K - V | Ms], [T | Ts]) :-
    python_json_dumps(V) = yes(VT),
    T = python_json_string(K) ++ ": " ++ VT,
    python_json_members(Ms, Ts).

:- func python_json_string(string) = string.

python_json_string(S) = "\"" ++
    string.append_list(list.map(python_json_char, string.to_char_list(S)))
    ++ "\"".

:- func python_json_char(char) = string.

python_json_char(C) = Text :-
    Code = char.to_int(C),
    ( if Code = 0x22 then
        Text = "\\\""
    else if Code = 0x5c then
        Text = "\\\\"
    else if Code = 0x0a then
        Text = "\\n"
    else if Code = 0x0d then
        Text = "\\r"
    else if Code = 0x09 then
        Text = "\\t"
    else if Code = 0x08 then
        Text = "\\b"
    else if Code = 0x0c then
        Text = "\\f"
    else if Code >= 0x20, Code =< 0x7e then
        Text = string.from_char(C)
    else if Code < 0x10000 then
        Text = string.format("\\u%04x", [i(Code)])
    else
        V = Code - 0x10000,
        Text = string.format("\\u%04x\\u%04x",
            [i(0xd800 + (V >> 10)), i(0xdc00 + (V /\ 0x3ff))])
    ).

    % A refusal as libds's status text reads: `[-221] ...`.
    %
:- func refused_text(int, string) = string.

refused_text(Code, Text) = string.format("[%d] %s", [i(Code), s(Text)]).

    % A refusal as a driver that fails on it reports it.
    %
:- func refusal_text(refusal) = string.

refusal_text(refused(Why)) = Why.
refusal_text(refused_status(Code, Text)) = refused_text(Code, Text).

:- func engine_error_of(effect) = engine_error is semidet.

engine_error_of(eff_event(se_engine_error(Error, _))) = Error.

    % `fault_events`: the refusal's fault events, of the four kinds and in
    % stream order, must be exactly the list given. Fails when the fixture
    % names no `fault_events`, or when they agree.
    %
:- func fault_events_mismatch(json_members, list(effect)) = string is semidet.

fault_events_mismatch(Expect, Effects) = Why :-
    lookup_member(Expect, "fault_events", _),
    list.map((pred(J::in, S::out) is semidet :- J = j_string(S)),
        array_member(Expect, "fault_events"), Want),
    Got = list.filter_map(event_kind,
        list.filter((pred(Eff::in) is semidet :-
            engine_error_of(Eff) = _), Effects)),
    Got \= Want,
    Why = "runtime_error: refused as expected, but the stream's faults are ["
        ++ string.join_list(", ", Got) ++ "], want ["
        ++ string.join_list(", ", Want) ++ "]".

    % `fact_count_after` on a `runtime_error`: the live fact count once the
    % refusal has happened, which pins what a refused RHS left behind: the
    % actions before the refused one stand and the ones after it never ran
    % ([LERR.1.5]). Fails when the fixture names no count, or when they
    % agree. A refusal that halts fails a fixture that counts facts
    % ([LERR.1.4.7], [NCBK.2.9], [RCTS.1.2.25]).
    %
:- func fact_count_mismatch(json_members, engine) = string is semidet.

fact_count_mismatch(Expect, E) = Why :-
    lookup_member(Expect, "fact_count_after", WantJ),
    WantJ = j_int(Want),
    ( if engine_halted(E) = yes(_) then
        Why = "runtime_error: fact_count_after, but the refusal left the "
            ++ "engine halted, whose working memory is not read "
            ++ "([RCTS.1.2.25])"
    else
        Got = engine_fact_count(E),
        int64.from_int(Got) \= Want,
        Why = string.format("runtime_error: refused as expected, but "
            ++ "fact_count_after: want %s got %d",
            [s(int64_to_string(Want)), i(Got)])
    ).

    % `last_event` on a `runtime_error`: the kind of the last event on the
    % stream once the refusal has happened. With
    % `engine_error` it pins that the EngineError is the tier's last record
    % ([LERR.1.4.7]). Fails when the fixture names no `last_event`, or when
    % they agree.
    %
:- func last_event_mismatch(json_members, list(effect)) = string is semidet.

last_event_mismatch(Expect, Effects) = Why :-
    lookup_member(Expect, "last_event", WantJ),
    WantJ = j_string(Want),
    Kinds = list.filter_map(event_kind, Effects),
    ( if list.last(Kinds, Last) then
        Last \= Want,
        Got = Last
    else
        Got = "no event"
    ),
    Why = "runtime_error: refused as expected, but the stream's last event "
        ++ "is " ++ Got ++ ", want " ++ Want.

    % `halted_fault` on a `runtime_error`: once the fault has happened, the
    % halt latch ([NCBK.2.11]) must hold an EngineError carrying the named
    % `EngineFault`. Fails when the fixture names no `halted_fault`, or when
    % the latch holds that fault.
    %
:- func halted_fault_mismatch(json_members, engine) = string is semidet.

halted_fault_mismatch(Expect, E) = Why :-
    lookup_member(Expect, "halted_fault", WantJ),
    ( if
        WantJ = j_string(Want),
        engine_fault_number(Want, WantN)
    then
        ( if
            engine_halted(E) = yes(Err),
            halt_fault(Err) = GotN
        then
            GotN \= WantN,
            Why = string.format("runtime_error: refused as expected, but "
                ++ "the halt latch holds EngineFault %d, want %s",
                [i(uint32.cast_to_int(GotN)), s(Want)])
        else
            Why = "runtime_error: refused as expected, but the halt latch "
                ++ "holds no EngineFault, want " ++ Want
        )
    else
        Why = "runtime_error: halted_fault " ++ string.string(WantJ)
            ++ " names no EngineFault member"
    ).

    % The `EngineFault` (`proto/engine_fault.proto`) an engine error that
    % halts the tier carries: `ds.fault.expr_engine_fault` for an expression
    % fault, ORDER_KEY for a duplicate order key. Fails for one that halts
    % nothing.
    %
:- func halt_fault(engine_error) = uint32 is semidet.

halt_fault(ee_expr_fault(F)) = expr_engine_fault(F).
halt_fault(ee_duplicate_order_key) = 4u32.

    % `pyds.EngineFault`'s members, by name, with their numbers.
    %
:- pred engine_fault_number(string::in, uint32::out) is semidet.

engine_fault_number("ARTEFACT_LIED", 1u32).
engine_fault_number("PATTERN_INDEX", 2u32).
engine_fault_number("BINDING_ORDER", 3u32).
engine_fault_number("ORDER_KEY", 4u32).
engine_fault_number("ALLOCATION", 6u32).
engine_fault_number("PUMP_WCET", 7u32).

    % `libds.h`'s code and libds's status text, for the refusals this runtime
    % raises as events.
    %
:- pred libds_status(engine_error::in, int::out, string::out) is semidet.

libds_status(ee_slot_invalid(_, sr_nan_rejected), -216,
    "NaN Float rejected at assert; a slot must be finite or Inf").
libds_status(ee_contract_breach(cap_wm_max), -606,
    "wm_assert: N_max exceeded").
libds_status(ee_contract_breach(cap_value_capacity), -710,
    "String longer than its slot's capacity (LSTR.11.3)").
libds_status(ee_contract_breach(cap_series), -710,
    "series: a sample past the series capacity (LSER.13.14)").
libds_status(ee_contract_breach(cap_cache), -710,
    "cache: contract cache_cap (live keys) exceeded").

    % `clone_determinism` [LDET.2.2b]: `steps` on one engine; `after_clone`
    % on it and on its clone, whose post-clone streams must agree; then
    % `after_free` on the survivor, which must go on firing.
    %
    % Here a clone is the same value used twice, so the two post-clone runs
    % agree by construction; this runtime has no clone code to be wrong, and
    % the vector pins libds's `ds_engine_clone`. What this half holds is the
    % vector's counts, so a vector that compares nothing or fires nothing
    % fails in both runtimes.
    %
    % The two streams are compared as the text of every stamped effect, in
    % order.
    %
    % `free` has nothing to do: a value is released when nothing refers to it.
    % The survivor is the first run's engine whichever side `free` names, as
    % the two are equal.
    %
:- func run_clone_determinism(json_members, program) = behave_result.

run_clone_determinism(Expect, P) = Result :-
    Kind = "clone_determinism",
    set_clock(from_ns(0u64), _, fixture_engine(P), E0),
    run_steps(P, array_member(Expect, "steps"), E0, E1, map.init, H1,
        [], _, Status0),
    AfterClone = array_member(Expect, "after_clone"),
    run_steps(P, AfterClone, E1, EA, H1, HA, [], RevA, StatusA),
    run_steps(P, AfterClone, E1, _, H1, _, [], RevB, StatusB),
    MinEvents = ( if int_member(Expect, "min_events", ME) then ME else 1 ),
    MinFires = ( if int_member(Expect, "min_rule_fires", MF) then MF else 1 ),
    MinTail = ( if int_member(Expect, "min_rule_fires_after_free", MT)
                then MT else 1 ),
    ( if
        lookup_member(Expect, "free", FreeJ),
        not ( FreeJ = j_string("source") ; FreeJ = j_string("clone") )
    then
        Result = behave_result(bo_fail, Kind,
            "`free` must be \"source\" or \"clone\"")
    else if status_outcome(Kind, Status0) = yes(R0) then
        Result = R0
    else if status_outcome(Kind, StatusA) = yes(RA) then
        Result = RA
    else if status_outcome(Kind, StatusB) = yes(RB) then
        Result = RB
    else
        IT = engine_interns(EA),
        EffA = list.condense(list.map(stamped_effects, list.reverse(RevA))),
        Events = list.length(list.filter_map(event_kind, EffA)),
        Fires = list.length(list.filter_map(fire_name(IT), EffA)),
        ( if Events < MinEvents then
            Result = behave_result(bo_fail, Kind,
                string.format("the post-clone stream has %d event(s), "
                    ++ "fewer than %d", [i(Events), i(MinEvents)]))
        else if Fires < MinFires then
            Result = behave_result(bo_fail, Kind,
                string.format("the post-clone stream has %d rule fire(s), "
                    ++ "fewer than %d", [i(Fires), i(MinFires)]))
        else if string.string(RevA) \= string.string(RevB) then
            Result = behave_result(bo_fail, Kind,
                "the two post-clone runs from one engine differ")
        else
            run_steps(P, array_member(Expect, "after_free"), EA, ET, HA, _,
                [], RevT, StatusT),
            ( if status_outcome(Kind, StatusT) = yes(RT) then
                Result = RT
            else
                EffT = list.condense(list.map(stamped_effects,
                    list.reverse(RevT))),
                Tail = list.length(list.filter_map(
                    fire_name(engine_interns(ET)), EffT)),
                ( if Tail < MinTail then
                    Result = behave_result(bo_fail, Kind,
                        string.format("after the free the survivor made %d "
                            ++ "rule fire(s), fewer than %d",
                            [i(Tail), i(MinTail)]))
                else
                    Result = behave_result(bo_pass, Kind, "")
                )
            )
        )
    ).

    % What a step run that did not finish makes of the fixture, or `no` if it
    % finished. A refusal fails it.
    %
:- func status_outcome(string, run_status) = maybe(behave_result).

status_outcome(_, run_ok) = no.
status_outcome(Kind, run_unsupported(Why)) =
    yes(behave_result(bo_unsupported, Kind, Why)).
status_outcome(Kind, run_refused(Refusal)) =
    yes(behave_result(bo_fail, Kind, refusal_text(Refusal))).

:- func run_fact_count(json_members, program)
    = {behave_result, maybe(list(string))}.

run_fact_count(Expect, P) = {Result, Fired} :-
    Kind = "runtime_fact_count",
    E0 = fixture_engine(P),
    Seeds = list.map(seed_step, array_member(Expect, "cache_seeds")),
    Asserts = list.map(assert_step, array_member(Expect, "asserts")),
    Generated = list.condense(list.map(generated_steps,
        array_member(Expect, "generate_asserts"))),
    ( if lookup_member(Expect, "pump", PumpJ), PumpJ = j_bool(yes) then
        Pump = [j_object(object(["op" - j_string("pump")]))]
    else
        Pump = []
    ),
    run_steps(P, Seeds ++ Asserts ++ Generated ++ Pump, E0, E, map.init, _,
        [], Rev, Status),
    (
        Status = run_unsupported(Why),
        Result = behave_result(bo_unsupported, Kind, Why),
        Fired = no
    ;
        Status = run_refused(Refusal),
        Result = behave_result(bo_fail, Kind, refusal_text(Refusal)),
        Fired = no
    ;
        Status = run_ok,
        Fired = yes(list.filter_map(fire_name(engine_interns(E)),
            list.condense(list.map(stamped_effects, list.reverse(Rev))))),
        ( if
            lookup_member(Expect, "fact_count_after", WantJ),
            WantJ = j_int(Want)
        then
            Got = engine_fact_count(E),
            ( if int64.from_int(Got) = Want then
                Result = behave_result(bo_pass, Kind, "")
            else
                Result = behave_result(bo_fail, Kind,
                    string.format("fact_count_after: want %s got %d",
                        [s(int64_to_string(Want)), i(Got)]))
            )
        else
            Result = behave_result(bo_unsupported, Kind,
                "no integer `fact_count_after`")
        )
    ).

    % `adapter_mock` ([LCON.4.3.1]): the steps on a mock clock at 0, then the
    % integrator played to a fixed point. In each round, every `call` issued so
    % far to a service `mocks` names, whose correlation has not been answered,
    % is answered by asserting `respond_schema` with `respond_slots` and
    % `corr` set to that correlation (`plan_response`); the round ends with
    % a pump. It stops when a round answers nothing, and after 64 rounds at
    % most. Then any `expected_logs` must be every `action_log` message in
    % order, any `expected_call_count` the number of calls issued (to mocked
    % services or not), and any `fact_count_after` the live fact count.
    %
    % The calls are the engine's `se_call_issued` events (`delivered_call`).
    % A correlation is answered once whatever its service, and a call to an
    % un-mocked service is never answered.
    %
:- func run_adapter_mock(json_members, program)
    = {behave_result, maybe(list(string))}.

run_adapter_mock(Expect, P) = {Result, Fired} :-
    Kind = "adapter_mock",
    set_clock(from_ns(0u64), _, fixture_engine(P), E0),
    Mocks = list.filter_map(
        (func(J::in) = (Mock::out) is semidet :-
            J = j_object(M),
            lookup_member(M, "service", j_string(Service)),
            Mock = Service - M),
        array_member(Expect, "mocks")),
    run_steps(P, array_member(Expect, "steps"), E0, E1, map.init, H1,
        [], Rev1, Status0),
    ( if Status0 = run_ok then
        deliver_mocks(P, Mocks, 64, [], E1, E, H1, _, Rev1, Rev, Status)
    else
        E = E1,
        Rev = Rev1,
        Status = Status0
    ),
    (
        Status = run_unsupported(Why),
        Result = behave_result(bo_unsupported, Kind, Why),
        Fired = no
    ;
        Status = run_refused(Refusal),
        Result = behave_result(bo_fail, Kind, refusal_text(Refusal)),
        Fired = no
    ;
        Status = run_ok,
        Effects = list.condense(list.map(stamped_effects, list.reverse(Rev))),
        Fired = yes(list.filter_map(fire_name(engine_interns(E)), Effects)),
        Calls = list.filter_map(delivered_call(engine_interns(E)), Effects),
        Logs = list.filter_map(log_message, Effects),
        ( if
            lookup_member(Expect, "expected_logs", _),
            Want = string_array(array_member(Expect, "expected_logs")),
            Want \= Logs
        then
            Result = behave_result(bo_fail, Kind,
                "continuation logs: want [" ++ string.join_list(", ", Want)
                    ++ "], got [" ++ string.join_list(", ", Logs) ++ "]")
        else if
            int_member(Expect, "expected_call_count", WantCalls),
            WantCalls \= list.length(Calls)
        then
            Result = behave_result(bo_fail, Kind,
                string.format("call count: want %d, got %d",
                    [i(WantCalls), i(list.length(Calls))]))
        else if
            int_member(Expect, "fact_count_after", WantFacts),
            WantFacts \= engine_fact_count(E)
        then
            Result = behave_result(bo_fail, Kind,
                string.format("fact_count_after: want %d, got %d",
                    [i(WantFacts), i(engine_fact_count(E))]))
        else
            Result = behave_result(bo_pass, Kind, "")
        )
    ).

    % One round of the mock integrator, then the next, until a round answers
    % nothing or `Left` runs out.
    %
:- pred deliver_mocks(program::in, assoc_list(string, json_members)::in,
                      int::in, list(maybe(string))::in, engine::in, engine::out,
                      map(string, fact_id)::in, map(string, fact_id)::out,
                      list(stamped)::in, list(stamped)::out,
                      run_status::out) is det.

deliver_mocks(P, Mocks, Left, Answered0, !E, !Handles, !Rev, Status) :-
    Effects = list.condense(list.map(stamped_effects, list.reverse(!.Rev))),
    Calls = list.filter_map(delivered_call(engine_interns(!.E)), Effects),
    list.foldl2(plan_response(Mocks), Calls, Answered0, Answered,
        [], RevResponses),
    ( if
        Left > 0,
        RevResponses = [_ | _]
    then
        Pump = j_object(object(["op" - j_string("pump")])),
        run_steps(P, list.reverse(RevResponses) ++ [Pump], !E, !Handles,
            !Rev, Round),
        (
            Round = run_ok,
            deliver_mocks(P, Mocks, Left - 1, Answered, !E, !Handles, !Rev,
                Status)
        ;
            ( Round = run_unsupported(_)
            ; Round = run_refused(_)
            ),
            Status = Round
        )
    else
        Status = run_ok
    ).

    % The response a mocked call gets, as an `assert` step, unless its
    % correlation is already answered or its service is not mocked.
    %
    % `corr` is the call's own correlation, `null` for an empty one, though
    % every call carries a non-empty one ([LCRS.3.1]). A mock without a
    % `respond_schema` answers nothing: there is no built-in response schema
    % ([LCRS.4.3.1]).
    %
:- pred plan_response(assoc_list(string, json_members)::in, call_seen::in,
                      list(maybe(string))::in, list(maybe(string))::out,
                      list(json)::in, list(json)::out) is det.

plan_response(Mocks, call_seen(Service, Corr, _), !Answered, !RevSteps) :-
    ( if
        not list.member(Corr, !.Answered),
        assoc_list.search(Mocks, Service, Mock),
        lookup_member(Mock, "respond_schema", j_string(Schema))
    then
        Given = ( if lookup_member(Mock, "respond_slots", j_object(RS))
                  then members(RS) else [] ),
        CorrJ = ( if Corr = yes(C) then j_string(C) else j_null ),
        Slots = ["corr" - CorrJ
            | list.negated_filter((pred(K - _::in) is semidet :- K = "corr"),
                Given)],
        Step = j_object(object([
            "op" - j_string("assert"),
            "schema" - j_string(Schema),
            "slots" - j_object(object(Slots))
        ])),
        !:Answered = [Corr | !.Answered],
        !:RevSteps = [Step | !.RevSteps]
    else
        true
    ).

    % `hash_order_independence` [LCON.2.4]: for each of `orders`, a fresh
    % engine on a mock clock at 0 asserts `schema(slot = v)` for v in that
    % order, pumps if `pump` (default yes), and the rule-fire order and live
    % fact count are taken. Every order must agree with the first, and the
    % first with any `expected_fire_order`.
    %
    % For this runtime it is a test of the agenda, not of hashing: no hash
    % table is iterated, but alpha memories keep insertion order and fact ids
    % and timetags follow assertion order, so [LDET.5]'s agenda ordering is
    % what keeps the order from showing through.
    %
:- func run_hash_order(json_members, program) = behave_result.

run_hash_order(Expect, P) = Result :-
    Kind = "hash_order_independence",
    ( if
        lookup_member(Expect, "schema", SJ), SJ = j_string(Schema),
        lookup_member(Expect, "slot", LJ), LJ = j_string(Slot),
        Orders = array_member(Expect, "orders"),
        Orders = [First, _ | _]
    then
        Pump = ( if lookup_member(Expect, "pump", PJ), PJ = j_bool(no)
                 then no else yes ),
        Runs0 = list.map(order_run(P, Schema, Slot, Pump), Orders),
        Runs = list.map(order_ran, Runs0),
        ( if
            list.find_first_map(
                (pred(R::in, Why::out) is semidet :- R = order_refused(Why)),
                Runs0, Refused)
        then
            Result = behave_result(bo_fail, Kind, Refused)
        else if
            list.find_first_match((pred(R::in) is semidet :- R = no), Runs, _)
        then
            Result = behave_result(bo_unsupported, Kind,
                "an order that is not a list of Ints or Strings, or an "
                ++ "assert this driver does not model")
        else if
            Runs = [yes(Base) | Rest],
            list.find_first_match(
                (pred(R::in) is semidet :- R = yes(Other), Other \= Base),
                Rest, DiffRun),
            DiffRun = yes(Diff)
        then
            Result = behave_result(bo_fail, Kind,
                "orders disagree: " ++ string.string(First) ++ " gives "
                    ++ string.string(Base) ++ ", another gives "
                    ++ string.string(Diff))
        else if
            Runs = [yes({BaseFires, _}) | _],
            lookup_member(Expect, "expected_fire_order", _),
            string_array(array_member(Expect, "expected_fire_order"))
                \= BaseFires
        then
            Result = behave_result(bo_fail, Kind,
                "fire order " ++ string.string(BaseFires) ++ " != expected "
                    ++ string.string(string_array(
                        array_member(Expect, "expected_fire_order"))))
        else
            Result = behave_result(bo_pass, Kind, "")
        )
    else
        Result = behave_result(bo_unsupported, Kind,
            "needs `schema`, `slot` and at least two `orders`")
    ).

    % One order's (fire names, live fact count); `order_unsupported` where the
    % order or an assert is not something this driver models; `order_refused`
    % where the engine refused an assert, which fails the fixture.
    %
:- type order_outcome
    --->    order_ok({list(string), int})
    ;       order_unsupported
    ;       order_refused(string).

:- func order_ran(order_outcome) = maybe({list(string), int}).

order_ran(order_ok(Run)) = yes(Run).
order_ran(order_unsupported) = no.
order_ran(order_refused(_)) = no.

:- func order_run(program, string, string, bool, json) = order_outcome.

order_run(P, Schema, Slot, Pump, OrderJ) = Run :-
    ( if
        OrderJ = j_array(Vs),
        % An Int or a String: a String key reaches the intern table, the
        % layout [LCON.2.4.1] names.
        list.all_true(
            (pred(X::in) is semidet :- ( X = j_int(_) ; X = j_string(_) )),
            Vs)
    then
        Asserts = list.map(
            (func(J) = j_object(object([
                "op" - j_string("assert"),
                "schema" - j_string(Schema),
                "slots" - j_object(object([Slot - J]))]))),
            Vs),
        Steps = Asserts ++ ( if Pump = yes
            then [j_object(object(["op" - j_string("pump")]))] else [] ),
        E0 = fixture_engine(P),
        set_clock(from_ns(0u64), _, E0, E1),
        run_steps(P, Steps, E1, E, map.init, _, [], RevStamped, Status),
        (
            Status = run_ok,
            IT = engine_interns(E),
            Effects = list.condense(list.map(stamped_effects,
                list.reverse(RevStamped))),
            Run = order_ok({list.filter_map(fire_name(IT), Effects),
                engine_fact_count(E)})
        ;
            Status = run_unsupported(_),
            Run = order_unsupported
        ;
            Status = run_refused(Refusal),
            Run = order_refused(refusal_text(Refusal))
        )
    else
        Run = order_unsupported
    ).

    % A runtime fixture's `asserts` entry as an `assert` step.
    %
:- func assert_step(json) = json.

assert_step(Entry) = Step :-
    ( if Entry = j_object(M) then
        Step = j_object(object(["op" - j_string("assert") | members(M)]))
    else
        Step = Entry
    ).

    % A `cache_seed` step's text: its `text` as written, its `text_bytes` as
    % those octets ([LSTR.8.5]), or its `value` as `python_json_dumps` writes
    % it; `no` for a value that function cannot write or octets no `string`
    % holds. Fails with none of the three.
    %
:- pred seed_step_text(json_members::in, maybe(string)::out) is semidet.

seed_step_text(Ms, SeedText) :-
    ( if lookup_member(Ms, "text", j_string(Given)) then
        SeedText = yes(Given)
    else if lookup_member(Ms, "text_bytes", j_string(Hex)) then
        ( if text_of_octets(Hex, Octets) then
            SeedText = yes(Octets)
        else
            SeedText = no
        )
    else
        lookup_member(Ms, "value", Value),
        SeedText = python_json_dumps(Value)
    ).

    % A runtime fixture's `cache_seeds` entry as a `cache_seed` step.
    %
:- func seed_step(json) = json.

seed_step(Entry) = Step :-
    ( if Entry = j_object(M) then
        Step = j_object(object(["op" - j_string("cache_seed") | members(M)]))
    else
        Step = Entry
    ).

    % `{schema, slot_name, start, count}` as `count` assert steps.
    %
:- func generated_steps(json) = list(json).

generated_steps(Gen) = Steps :-
    ( if
        Gen = j_object(Ms),
        lookup_member(Ms, "schema", SchemaJ),
        lookup_member(Ms, "slot_name", SlotJ),
        SlotJ = j_string(Slot),
        lookup_member(Ms, "count", CountJ),
        CountJ = j_int(Count64),
        Count = int64.cast_to_int(Count64)
    then
        ( if lookup_member(Ms, "start", StartJ), StartJ = j_int(S) then
            Start = int64.cast_to_int(S)
        else
            Start = 0
        ),
        Steps = list.map((func(N) = j_object(object([
                "op" - j_string("assert"),
                "schema" - SchemaJ,
                "slots" - j_object(object([Slot - j_int(int64.from_int(N))]))]))),
            int.fold_up(func(N, Acc) = Acc ++ [N], Start, Start + Count - 1,
                []))
    else
        Steps = [j_object(object(["op" - j_string("malformed")]))]
    ).

%-----------------------------------------------------------------------------%

:- type run_status
    --->    run_ok
    ;       run_unsupported(string)
    ;       run_refused(refusal).
            % A host call the engine refused. It stops the steps, as pyds's
            % raise does, and every driver but `run_runtime_error` fails on
            % it.

    % Which refusal, because `runtime_error` judges the two differently.
    %
:- type refusal
    --->    refused(string)
            % The refusal wrote its fault as an `se_engine_error`, which
            % `runtime_error` finds in the effects and checks. The string
            % names the refused call, for a driver that fails on it.
    ;       refused_status(int, string).
            % A host call refused with this libds status that wrote nothing,
            % such as a `Json` value over a limit ([LGRA.5.8.6]).
            % `runtime_error` judges it on the status alone.

    % One step's effects, with the engine clock as the step left it.
    %
    % The clock is read after the step, the instant its events were emitted
    % at: a `set` or `advance` moves the clock before its tick, and nothing
    % inside an assert or a pump moves it. That is the `clock_ns` a libds
    % stream callback carries for the same events.
    %
:- type stamped == {instant, list(effect)}.

:- func stamped_effects(stamped) = list(effect).

stamped_effects({_, Effects}) = Effects.

:- pred run_steps(program::in, list(json)::in, engine::in, engine::out,
                  map(string, fact_id)::in, map(string, fact_id)::out,
                  list(stamped)::in, list(stamped)::out,
                  run_status::out) is det.

run_steps(_, [], !E, !Handles, !RevEffects, run_ok).
run_steps(P, [Step | Steps], !E, !Handles, !RevEffects, Status) :-
    Before = list.length(!.RevEffects),
    run_step(P, Step, StepStatus0, !E, !Handles, !RevEffects),
    list.take_upto(list.length(!.RevEffects) - Before, !.RevEffects, Pushed),
    StepStatus = rcts_1_2_27_step(Step,
        list.condense(list.map(stamped_effects, Pushed)), StepStatus0),
    (
        StepStatus = run_ok,
        run_steps(P, Steps, !E, !Handles, !RevEffects, Status)
    ;
        ( StepStatus = run_unsupported(_)
        ; StepStatus = run_refused(_)
        ),
        Status = StepStatus
    ).

    % `run_steps`, noting the status each `pump` step reports, in step order
    % (`pump_status_code`), for [RCTS.1.2.30]'s `expected_pump_statuses`.
    % Each step runs through `run_steps`, so it is judged exactly as there.
    %
:- pred run_steps_statuses(program::in, list(json)::in,
                           engine::in, engine::out,
                           map(string, fact_id)::in, map(string, fact_id)::out,
                           list(stamped)::in, list(stamped)::out,
                           list(int)::in, list(int)::out,
                           run_status::out) is det.

run_steps_statuses(_, [], !E, !Handles, !RevEffects, !RevStatuses, run_ok).
run_steps_statuses(P, [Step | Steps], !E, !Handles, !RevEffects, !RevStatuses,
        Status) :-
    Before = list.length(!.RevEffects),
    run_steps(P, [Step], !E, !Handles, !RevEffects, StepStatus),
    ( if pump_step(Step) then
        list.take_upto(list.length(!.RevEffects) - Before, !.RevEffects,
            Pushed),
        !:RevStatuses = [pump_status_code(
            list.condense(list.map(stamped_effects, Pushed))) | !.RevStatuses]
    else
        true
    ),
    (
        StepStatus = run_ok,
        run_steps_statuses(P, Steps, !E, !Handles, !RevEffects, !RevStatuses,
            Status)
    ;
        ( StepStatus = run_unsupported(_)
        ; StepStatus = run_refused(_)
        ),
        Status = StepStatus
    ).

    % `run_steps`, one step at a time, for a `replay_determinism` fixture
    % that carries `tamper` ([RCTS.1.2.21]): the step during which the
    % engine halts (`run_step`'s -10) is the run's outcome when it is the
    % last step, and fails the fixture when steps follow it, since a halted
    % engine refuses them ([RCTS.1.2.28]). Any other refusal stands. The
    % halting step's effects, its EngineError among them, are kept: they are
    % what the recording holds and the replay must reproduce.
    %
:- pred run_halting_steps(program::in, list(json)::in,
                          engine::in, engine::out,
                          map(string, fact_id)::in, map(string, fact_id)::out,
                          list(stamped)::in, list(stamped)::out,
                          run_status::out) is det.

run_halting_steps(_, [], !E, !Handles, !RevEffects, run_ok).
run_halting_steps(P, [Step | Steps], !E, !Handles, !RevEffects, Status) :-
    run_steps(P, [Step], !E, !Handles, !RevEffects, StepStatus),
    Halted = ( if engine_halted(!.E) = yes(_) then yes else no ),
    Next = halting_step(StepStatus, Halted, Steps),
    (
        Next = next_step,
        run_halting_steps(P, Steps, !E, !Handles, !RevEffects, Status)
    ;
        Next = stop(Status)
    ).

:- type halting_step
    --->    next_step
    ;       stop(run_status).

    % `run_halting_steps`' decision for one step, given its status, whether
    % the engine is halted after it, and the steps after it.
    %
:- func halting_step(run_status, bool, list(json)) = halting_step.

halting_step(StepStatus, Halted, Rest) = Next :-
    ( if StepStatus = run_ok then
        Next = next_step
    else if
        StepStatus = run_refused(refused_status(-10, _)),
        Halted = yes
    then
        (
            Rest = [],
            Next = stop(run_ok)
        ;
            Rest = [_ | _],
            Next = stop(run_refused(refused(string.format(
                "replay_determinism: a step halted the engine and %d step(s) "
                    ++ "follow it; the halting step must be the last "
                    ++ "([RCTS.1.2.28])", [i(list.length(Rest))]))))
        )
    else
        Next = stop(StepStatus)
    ).

:- pred pump_step(json::in) is semidet.

pump_step(j_object(Ms)) :-
    lookup_member(Ms, "op", j_string("pump")).

    % [RCTS.1.2.30]: the status a pump reports, as libds's number, 0 for none.
    % It is the pump's first `eff_pump_status` (`first_pump_status`): what
    % libds stashes with `ds_engine_set_pending` and returns from
    % `ds_engine_pump`.
    %
    % A pump that halts the engine never reaches here as a status: libds
    % returns DS_ERR_ENGINE_HALTED from it ([NCBK.2.9]), and here `run_step`
    % refuses the step, which ends the steps. So a vector that pinned -10 in
    % `expected_pump_statuses` would fail here and pass under libds.
    %
:- func pump_status_code(list(effect)) = int.

pump_status_code(Effects) =
    ( if first_pump_status(Effects) = yes(S) then libds_pump_status(S)
    else 0 ).

    % `libds.h`'s number for each status a pump reports. A switch, so a new
    % `pump_status` is a compile error here until it has its number.
    %
:- func libds_pump_status(pump_status) = int.

libds_pump_status(ps_nan_rejected) = -216.          % DS_ERR_NAN_REJECTED
libds_pump_status(ps_contract_breach(_)) = -710.    % DS_ERR_CONTRACT_BREACH
libds_pump_status(ps_time_range) = -205.            % DS_ERR_TIME_RANGE

    % [RCTS.1.2.30]: with `expected_pump_statuses`, the pumps' statuses must
    % be the array; without it, a pump that reports one fails the fixture
    % ([RCTS.1.2.28]). Judged before the calls. `kind_fields_placed` has
    % already refused a field of another shape.
    %
:- func pump_statuses_result(string, json_members, list(int), behave_result)
    = behave_result.

pump_statuses_result(Kind, Expect, Got, Result0) = Result :-
    ( if
        lookup_member(Expect, "expected_pump_statuses", WantJ),
        pump_status_array(WantJ, Want)
    then
        ( if Want = Got then
            Result = Result0
        else
            Result = behave_result(bo_fail, Kind, "pump statuses: want "
                ++ ints_text(Want) ++ ", got " ++ ints_text(Got))
        )
    else if list.find_first_match((pred(S::in) is semidet :- S \= 0), Got,
            Reported) then
        Result = behave_result(bo_fail, Kind, string.format(
            "a pump reported %d, and the fixture carries no "
            ++ "expected_pump_statuses to state it ([RCTS.1.2.28], "
            ++ "[RCTS.1.2.30])", [i(Reported)]))
    else
        Result = Result0
    ).

    % An `expected_pump_statuses` of the shape [RCTS.1.2.30] states: an array
    % of integers each 0 or less.
    %
:- pred pump_status_array(json::in, list(int)::out) is semidet.

pump_status_array(j_array(Js), Statuses) :-
    list.map(
        (pred(SJ::in, S::out) is semidet :-
            SJ = j_int(S64),
            S64 =< 0i64,
            S = int64.cast_to_int(S64)),
        Js, Statuses).

:- func ints_text(list(int)) = string.

ints_text(Is) =
    "[" ++ string.join_list(", ", list.map(string.int_to_string, Is)) ++ "]".

    % [RCTS.1.2.27]: a step carrying `refused` must be refused with that
    % status, and the steps then go on; its effects, the recorded assert and
    % its fault, stay in the list ([RFCS.6.7]). A step with no `refused`, or
    % one whose `refused` is not a string, keeps its status:
    % `rcts_1_2_27_refusal` fails the second, and every kind but
    % `rfcs_roundtrip` that carries one.
    %
:- func rcts_1_2_27_step(json, list(effect), run_status) = run_status.

rcts_1_2_27_step(Step, StepEffects, Status0) = Status :-
    ( if
        Step = j_object(Ms),
        lookup_member(Ms, "refused", WantJ),
        WantJ = j_string(Want)
    then
        (
            Status0 = run_ok,
            Status = run_refused(refused("the assert was admitted; the step "
                ++ "wants it refused with " ++ Want ++ " ([RCTS.1.2.27])"))
        ;
            Status0 = run_unsupported(_),
            Status = Status0
        ;
            Status0 = run_refused(Refusal),
            Got = refusal_code(Refusal, StepEffects),
            ( if Got = yes(Code), string.int_to_string(Code) = Want then
                Status = run_ok
            else
                Status = run_refused(refused("the assert was refused with "
                    ++ string.string(Got) ++ "; the step wants " ++ Want
                    ++ " ([RCTS.1.2.27])"))
            )
        )
    else
        Status = Status0
    ).

    % The status a refusal carries: its own, or that of the fault its step
    % raised as an event, as `libds_status` maps the fault to libds's code.
    %
:- func refusal_code(refusal, list(effect)) = maybe(int).

refusal_code(refused_status(Code, _), _) = yes(Code).
refusal_code(refused(_), Effects) = MaybeCode :-
    ( if
        list.find_first_map(
            (pred(Eff::in, C::out) is semidet :-
                libds_status(engine_error_of(Eff), C, _)),
            Effects, Code)
    then
        MaybeCode = yes(Code)
    else
        MaybeCode = no
    ).

    % `run_steps`, noting the 0-based index of the first step that faults: a
    % step whose own effects carry an `se_engine_error`, or one the engine
    % refuses (`run_refused`). `run_runtime_error` reads it for `fault_at`.
    % Each step's effects are the stamped entries it pushed, so a step that
    % pushes none (`wall_set`) keeps its index and faults nothing.
    %
:- pred run_steps_faulting(program::in, list(json)::in, int::in,
                           maybe(int)::in, maybe(int)::out,
                           engine::in, engine::out,
                           map(string, fact_id)::in, map(string, fact_id)::out,
                           list(stamped)::in, list(stamped)::out,
                           run_status::out) is det.

run_steps_faulting(_, [], _, !FaultAt, !E, !Handles, !RevEffects, run_ok).
run_steps_faulting(P, [Step | Steps], At, !FaultAt, !E, !Handles,
        !RevEffects, Status) :-
    Before = list.length(!.RevEffects),
    run_step(P, Step, StepStatus, !E, !Handles, !RevEffects),
    list.take_upto(list.length(!.RevEffects) - Before, !.RevEffects, Pushed),
    StepEffects = list.condense(list.map(stamped_effects, Pushed)),
    ( if
        !.FaultAt = no,
        ( list.filter_map(engine_error_of, StepEffects) = [_ | _]
        ; StepStatus = run_refused(_)
        )
    then
        !:FaultAt = yes(At)
    else
        true
    ),
    (
        StepStatus = run_ok,
        run_steps_faulting(P, Steps, At + 1, !FaultAt, !E, !Handles,
            !RevEffects, Status)
    ;
        ( StepStatus = run_unsupported(_)
        ; StepStatus = run_refused(_)
        ),
        Status = StepStatus
    ).

    % The engine every executing fixture driver starts from: the mock clocks,
    % with the wall clock at the Unix epoch, as `runner.py` gives libds. A
    % mock wall clock is unset until set, and `now()` read while it is unset
    % faults. A fixture moves it with the `wall_set` step. Not used for
    % replay, whose clocks come from the recording.
    %
:- func fixture_engine(program) = engine.

fixture_engine(P) = E :-
    engine_use_mock_clock(init_engine(P), E0),
    set_wall_clock(0i64, E0, E).

    % The engine a fixture's `steps` start from, in `run_expectation` and
    % wherever a driver runs some of them again (`late_records`):
    % `fixture_engine`, or with `"wall_clock": "unset"` the mock clocks and
    % no wall clock, or for an `rfcs_roundtrip` the fixture's `run_id` and
    % `tier_id` ([RCTS.1.2.23]), with the clock set to 0.
    %
:- func steps_engine(string, json_members, program) = engine.

steps_engine(Kind, Expect, P) = E :-
    ( if
        lookup_member(Expect, "wall_clock", WallJ),
        WallJ = j_string("unset")
    then
        engine_use_mock_clock(init_engine(P), E0)
    else if Kind = "rfcs_roundtrip" then
        E0 = with_rfcs_ids(Expect, fixture_engine(P))
    else
        E0 = fixture_engine(P)
    ),
    set_clock(from_ns(0u64), _, E0, E).

    % A fixture's `cache_cap`, `{"keys": K, "bytes": B}`: the engine's cache
    % bounds ([LSTO.4.7.5], [NSTG.2.6.1]), either one 0 or absent for no
    % bound. Set before any input. A fixture without the member leaves the
    % cache unbounded.
    %
:- func with_cache_cap(json_members, engine) = engine.

with_cache_cap(Expect, E0) = E :-
    ( if lookup_member(Expect, "cache_cap", CapJ), CapJ = j_object(Cap) then
        Keys = ( if int_member(Cap, "keys", K) then K else 0 ),
        Bytes = ( if int_member(Cap, "bytes", B) then B else 0 ),
        set_cache_cap(uint32.det_from_int(Keys), uint64.det_from_int(Bytes),
            E0, E)
    else
        E = E0
    ).

    % One step, with [NCBK.2.9]'s status: the call during which the engine
    % raises an EngineError returns DS_ERR_ENGINE_HALTED, as libds's
    % `ds_recorder_api_leave` returns it. This runtime's calls report no
    % status, so the step is refused here when the engine was running before
    % it and is halted after it, with libds's words for that refusal
    % (`recorder.c`). A step the engine refused for another reason keeps that
    % refusal.
    %
:- pred run_step(program::in, json::in, run_status::out,
                 engine::in, engine::out,
                 map(string, fact_id)::in, map(string, fact_id)::out,
                 list(stamped)::in, list(stamped)::out) is det.

run_step(P, Step, Status, !E, !Handles, !RevEffects) :-
    Halted0 = engine_halted(!.E),
    run_step_call(P, Step, Status0, !E, !Handles, !RevEffects),
    ( if
        Status0 = run_ok,
        Halted0 = no,
        engine_halted(!.E) = yes(_),
        Step = j_object(Ms),
        lookup_member(Ms, "op", j_string(Op)),
        ( Op = "pump" ; Op = "assert" ; Op = "retract" )
    then
        Status = run_refused(refused_status(-10, "engine halted by an "
            ++ "EngineError during this call; state is no longer "
            ++ "trustworthy"))
    else
        Status = Status0
    ).

:- pred run_step_call(program::in, json::in, run_status::out,
                      engine::in, engine::out,
                      map(string, fact_id)::in, map(string, fact_id)::out,
                      list(stamped)::in, list(stamped)::out) is det.

run_step_call(P, Step, Status, !E, !Handles, !RevEffects) :-
    ( if
        Step = j_object(Ms),
        lookup_member(Ms, "op", OpJ),
        OpJ = j_string(Op)
    then
        ( if Op = "pump" then
            pump(default_budget, Effects, !E),
            !:RevEffects = [{engine_now(!.E), Effects} | !.RevEffects],
            Status = run_ok
        else if Op = "advance", int_member(Ms, "delta_ns", Ns), Ns >= 0 then
            advance(duration_from_ns(uint64.det_from_int(Ns)), Effects, !E),
            !:RevEffects = [{engine_now(!.E), Effects} | !.RevEffects],
            Status = run_ok
        else if Op = "set", int_member(Ms, "now_ns", At), At >= 0 then
            Instant = from_ns(uint64.det_from_int(At)),
            set_clock(Instant, Effects, !E),
            !:RevEffects = [{engine_now(!.E), Effects} | !.RevEffects],
            % `set_clock` refuses by leaving the clock where it was (below
            % the current instant after an input, [NTST.3.1]), where libds
            % answers DS_ERR_STATE; a refused step fails the fixture
            % ([RCTS.1.2.28]). The clock's source, `engine_clock_now`, not
            % `engine_now`: a set is not a sample. A halted engine moves no
            % clock either; that is an earlier step's fault.
            ( if
                ( engine_clock_now(!.E) = Instant
                ; engine_halted(!.E) = yes(_)
                )
            then
                Status = run_ok
            else
                Status = run_refused(refused_status(-4, "a set of the mock "
                    ++ "clock to " ++ string.int_to_string(At) ++ " ns is "
                    ++ "refused ([NTST.3.1])"))
            )
        else if Op = "wall_set", int_member(Ms, "utc_ns", Utc) then
            % [NTST.3.1]: the wall clock alone. Not a sample, so no effects
            % ([NTST.3.3]).
            set_wall_clock(int64.from_int(Utc), !E),
            Status = run_ok
        else if Op = "retract" then
            ( if
                lookup_member(Ms, "label", LabelJ),
                LabelJ = j_string(Label),
                map.search(!.Handles, Label, Id)
            then
                host_retract(Id, Effects, !E),
                !:RevEffects = [{engine_now(!.E), Effects} | !.RevEffects],
                Status = run_ok
            else
                Status = run_unsupported("retract of an unknown label")
            )
        else if
            Op = "cache_seed",
            lookup_member(Ms, "key", KeyJ),
            KeyJ = j_string(Key),
            seed_step_text(Ms, SeedText)
        then
            % [NSTG.9.1]: arrange, not a run: a seed writes nothing to the
            % stream on any outcome, so there are no effects to stamp.
            %
            % Handed text, as `runner.py` hands pyds `json.dumps(value)`: the
            % text is what [LGRA.5.8.6]'s text limit reads, so this runtime
            % parses the same bytes libds does. A `cache_seeds` entry's `text`
            % is handed over as written ([RCTS.1.2.25]).
            %
            % `ttl_ns` ([RCTS.1.2.28]), 0 or absent for no expiry, as libds's
            % DS_CACHE_TTL_NONE: the seed's TTL, which the engine holds as a
            % duration until its first sample ([NLFC.9.4]).
            ( if
                lookup_member(Ms, "ttl_ns", j_int(TtlNs)),
                TtlNs > 0i64
            then
                Ttl = yes(duration_from_ns(uint64.cast_from_int64(TtlNs)))
            else
                Ttl = no
            ),
            ( if SeedText = yes(Text) then
                seed_cache_text(Key, Text, Ttl, SeedResult, !E),
                Status = seed_status(SeedResult)
            else
                Status = run_unsupported("a cache seed holding a Float, "
                    ++ "whose Python `repr` text this driver does not write")
            )
        else if Op = "assert", int_member(Ms, "corr_from_call", N) then
            % `corr_from_call: N` fills the fact's `corr` slot with the
            % correlation the Nth call issued so far carried (0-based, in issue
            % order), for a call whose correlation the engine generated
            % ([LCCO.3.4]).
            ( if
                nth_call_corr(!.E, list.reverse(!.RevEffects), N, Corr)
            then
                assert_json(P, with_corr(Ms, Corr), Status, !E, !Handles,
                    !RevEffects)
            else
                Status = run_unsupported("`corr_from_call` names no call "
                    ++ "issued so far")
            )
        else if Op = "assert" then
            assert_json(P, Ms, Status, !E, !Handles, !RevEffects)
        else
            Status = run_unsupported("step op `" ++ Op ++ "`")
        )
    else
        Status = run_unsupported("a step with no `op`")
    ).

    % The correlation of the Nth call issued in a run (0-based), as the engine
    % rendered it. Every call carries one ([LCRS.3.1]); a call whose
    % correlation expression was left unevaluated is not counted.
    %
:- pred nth_call_corr(engine::in, list(stamped)::in, int::in, string::out)
    is semidet.

nth_call_corr(E, Stamped, N, Corr) :-
    Effects = list.condense(list.map(stamped_effects, Stamped)),
    Corrs = list.filter_map(call_corr(E), Effects),
    list.index0(Corrs, N, Corr).

:- func call_corr(engine, effect) = string is semidet.

call_corr(E, Eff) = Corr :-
    Eff = eff_event(Ev),
    Ev = se_call_issued(_, _, correlated(Ref), _, _),
    expand(engine_interns(E), Ref, Corr).

    % A step's members with `corr` set among its `slots`, replacing any given.
    %
:- func with_corr(json_members, string) = json_members.

with_corr(Ms, Corr) = object(Others ++ ["slots" - j_object(object(Slots))]) :-
    ( if lookup_member(Ms, "slots", SlotsJ), SlotsJ = j_object(S) then
        Given = members(S)
    else
        Given = []
    ),
    Slots = ["corr" - j_string(Corr)
        | list.negated_filter((pred(K - _::in) is semidet :- K = "corr"),
            Given)],
    Others = list.negated_filter((pred(K - _::in) is semidet :- K = "slots"),
        members(Ms)).

    % An `assert`, as `pyds`'s `assert_` makes it. A deadline comes only from
    % a `ttl` schema's own TTL.
    %
:- pred assert_json(program::in, json_members::in,
                    run_status::out, engine::in, engine::out,
                    map(string, fact_id)::in, map(string, fact_id)::out,
                    list(stamped)::in, list(stamped)::out) is det.

assert_json(P, Ms, Status, !E, !Handles, !RevEffects) :-
    ( if
        lookup_member(Ms, "schema", SchemaJ),
        SchemaJ = j_string(SchemaName),
        schema_by_name(P, SchemaName, Schema)
    then
        ( if lookup_member(Ms, "slots", SlotsJ), SlotsJ = j_object(S) then
            Slots = members(S)
        else
            Slots = []
        ),
        IT0 = interns(P),
        Names = list.filter_map(
            (func(C::in) = (N::out) is semidet :-
                expand(IT0, C ^ sc_name, N)),
            slot_commons(Schema)),
        ( if
            list.find_first_match(
                (pred(Given - _::in) is semidet :-
                    not list.member(Given, Names)),
                Slots, Unknown - _)
        then
            Status = run_unsupported("slot `" ++ Unknown ++ "` is not on `"
                ++ SchemaName ++ "`")
        else if
            % An omitted non-nullable slot is refused, as pyds refuses it
            % ("missing kwarg for slot"). `hydrated_corr` is the one
            % exception pyds makes; `slot_value` fills it.
            list.find_first_match(
                (pred(C::in) is semidet :-
                    C ^ sc_nullable = non_null,
                    expand(IT0, C ^ sc_name, N),
                    N \= "hydrated_corr",
                    not assoc_list.search(Slots, N, _)),
                slot_commons(Schema), Missing),
            expand(IT0, Missing ^ sc_name, MissingName)
        then
            Status = run_refused(refused("schema `" ++ SchemaName
                ++ "`: missing kwarg for slot `" ++ MissingName ++ "`"))
        else if
            % [RCTS.1.2.28]: `{"$text_bytes": H}` is a `String` value. A
            % refusal with no status, so a `runtime_error` fixture cannot
            % take it for the refusal it pins.
            list.find_first_match(
                (pred(C::in) is semidet :-
                    C ^ sc_kind \= k_string,
                    expand(IT0, C ^ sc_name, N),
                    assoc_list.search(Slots, N, GivenJ),
                    GivenJ = j_object(GivenO),
                    lookup_member(GivenO, "$text_bytes", _)),
                slot_commons(Schema), Misplaced),
            expand(IT0, Misplaced ^ sc_name, MisplacedName)
        then
            Status = run_refused(refused("slots." ++ MisplacedName
                ++ " gives {\"$text_bytes\": H}, a String value, to a slot "
                ++ "that is not a String ([RCTS.1.2.28])"))
        else
            list.map_foldl(slot_value(IT0, Slots), slot_commons(Schema),
                Values, !E),
            host_assert(Schema, Values, no, AssertResult, Effects, !E),
            !:RevEffects = [{engine_now(!.E), Effects} | !.RevEffects],
            ( if
                lookup_member(Ms, "as", AsJ),
                AsJ = j_string(Label),
                handle_of(AssertResult, Id)
            then
                map.set(Label, Id, !Handles)
            else
                true
            ),
            Status = assert_status(SchemaName, AssertResult)
        )
    else
        Status = run_unsupported("assert of a schema this program does not "
            ++ "declare")
    ).

    % What pyds does with a host assert's result: an insert, a replace and a
    % no-op re-assert return; every refusal raises (`run_refused`).
    %
:- func assert_status(string, assert_result) = run_status.

assert_status(Schema, R) = Status :-
    (
        ( R = inserted(_)
        ; R = noop(_)
        ; R = replaced(_, _)
        ),
        Status = run_ok
    ;
        % [NCBK.2.9]: a halted engine refuses the assert and records nothing,
        % so the refusal carries its status, DS_ERR_ENGINE_HALTED, and the
        % words libds's DS_ENGINE_REFUSE_IF_HALTED gives it (`engine.h`).
        R = refused_halted(_),
        Status = run_refused(refused_status(-10,
            "engine halted by an EngineError; state is no longer trustworthy"))
    ;
        ( R = rejected(_)
        ; R = invalid(_, _)
        ; R = refused_arity(_, _)
        ; R = refused_unregistered(_)
        ; R = refused_time_range(_)
        ; R = refused_encoding(_)
        ; R = refused_tz_row(_)
        ; R = refused_ttl_range
        ),
        ( if R = invalid(_, sr_json_limit(_)) then
            % Refused with no event ([LGRA.5.8.6]), so it carries its
            % status, DS_ERR_JSON_LIMIT, and the words every libds refusal of
            % one carries.
            Status = run_refused(refused_status(-221,
                "Json value over a DS_JSON_MAX_* limit"))
        else if R = invalid(_, sr_json_nonfinite) then
            % [LGRA.5.8.10]: a Json value holding a non-finite float,
            % refused with no event, so it carries its status,
            % DS_ERR_JSON_NONFINITE, and the words of the libds refusal pyds
            % meets building the value (`json.c`'s `ds_json_new_float`).
            Status = run_refused(refused_status(-217,
                "ds_json_new_float: a non-finite float, which a Json value "
                ++ "does not hold (LGRA.5.8.10)"))
        else if R = invalid(_, sr_nan_rejected) then
            % [LEXP.4.2]: a NaN, refused with no event ([NFCT.2.11]: the host
            % door's value steps record nothing), so it carries its
            % status, DS_ERR_NAN_REJECTED, and the words libds's host assert
            % gives it (`wm.c`).
            Status = run_refused(refused_status(-216,
                "NaN Float rejected at assert; a slot must be finite or Inf"))
        else if R = invalid(_, sr_null_non_nullable) then
            % [LNUL.3.1]: a `null` in a slot not declared `T?`, refused with no
            % event, so it carries its status, DS_ERR_SLOT_TYPE_MISMATCH, and
            % the words libds's host assert gives it (`wm.c`). A kind
            % mismatch's words name the declared type, which the reason does
            % not carry, so it keeps the refusal below.
            Status = run_refused(refused_status(-104,
                "null value in a non-nullable slot (LNUL.3.1)"))
        else if R = refused_time_range(_) then
            % [LTIM.1.2.2]: a `Date` outside its range, refused with no event
            % too, so it carries its status, DS_ERR_TIME_RANGE, and the words
            % libds's host assert gives it (`wm.c`).
            Status = run_refused(refused_status(-205,
                "assert: a Date outside the Date range, "
                ++ "1677-09-22 to 2262-04-11 ([LTIM.1.2.2])"))
        else if R = refused_encoding(_) then
            % [LSTR.8.5]: host text that is not well-formed UTF-8, refused
            % with no event, so it carries its status, DS_ERR_ENCODING, and
            % the words libds's host assert gives it (`wm.c`).
            Status = run_refused(refused_status(-222,
                "assert: a String or Json slot's text is not well-formed "
                ++ "UTF-8 ([LSTR.8.5])"))
        else if R = refused_tz_row(Fault) then
            % [LTIM.10.9]: a malformed `TimeZoneOffset` row, refused with no
            % event, so it carries its status, DS_ERR_INVAL, and the words
            % libds's host assert gives it (`wm.c`).
            Status = run_refused(refused_status(-1, ltim_10_9_message(Fault)))
        else if R = refused_ttl_range then
            % [RFCS.6.7]: a fact's TTL deadline past the
            % `Time` range, the schema's or an override's, refused with
            % DS_ERR_TIME_RANGE and the words libds's `wm.c` gives it.
            Status = run_refused(refused_status(-205,
                "assert: the fact's TTL deadline is outside the Time range "
                ++ "([RFCS.6.7])"))
        else
            Status = run_refused(refused("assert of `" ++ Schema
                ++ "` refused: " ++ string.string(R)))
        )
    ).

:- pred handle_of(assert_result::in, fact_id::out) is semidet.

handle_of(inserted(Id), Id).
handle_of(replaced(_, Id), Id).

:- pred schema_by_name(program::in, string::in, schema::out) is semidet.

schema_by_name(P, Name, Found) :-
    list.find_first_match(
        (pred(S::in) is semidet :-
            expand(interns(P), schema_name_ref(S ^ s_name), Name)),
        schemas(P), Found).

    % A slot's value from the step, by name. An integer given for a `Float`
    % slot is that float, as `pyds` converts it.
    %
    % An omitted slot is what pyds makes of it: `hydrated_corr` is `""`; a
    % nullable slot is `null` ([LNUL.4.1]), not the zero of its kind; a
    % non-nullable one never gets here, because `assert_json` has refused the
    % assert.
    %
    % A `Bytes` value is written `{"$bytes": "<hex>"}`, two hex digits per
    % octet, since a bare string is a `String` ([LEXP.7.19]). A malformed hex
    % string reads as `null`; a step that writes one fails its fixture before
    % it runs (`bytes_slot_reason`).
    %
:- pred slot_value(intern_table::in, assoc_list(string, json)::in,
                   slot_common::in, ds_value::out,
                   engine::in, engine::out) is det.

slot_value(IT, Slots, Common, Value, !E) :-
    ( if
        expand(IT, Common ^ sc_name, Name),
        assoc_list.search(Slots, Name, Given)
    then
        ( if Given = j_null then
            Value = null
        else if Common ^ sc_kind = k_json then
            % A `Json` slot takes the document as given, object, array or
            % scalar, as `pyds` marshals a Python value into a JSON tree.
            Value = json(Given)
        else if
            Given = j_object(Obj),
            members(Obj) = ["$bytes" - j_string(Hex)]
        then
            ( if hex_bytes(Hex, Octets) then
                Value = bytes(from_bytes(Octets))
            else
                Value = null
            )
        else if
            % [LSTR.8.5]: a `String` whose text is not well-formed UTF-8 is
            % written `{"$text_bytes": "<hex>"}` ([RCTS.1.2.28]), and reaches
            % the engine as those octets. `assert_json` has held the form to
            % `String` slots.
            Given = j_object(TObj),
            members(TObj) = ["$text_bytes" - j_string(THex)]
        then
            ( if text_of_octets(THex, Text0) then
                engine_intern(Text0, TRef, !E),
                Value = str(TRef)
            else
                Value = null
            )
        else if Given = j_int(I), Common ^ sc_kind = k_float then
            Value = float(float.cast_from_int64(I))
        else if Given = j_int(I2) then
            Value = int(I2)
        else if Given = j_float(F) then
            Value = float(F)
        else if Given = j_bool(B) then
            Value = bool(B)
        else if Given = j_string(Text) then
            engine_intern(Text, Ref, !E),
            Value = str(Ref)
        else
            Value = null
        )
    else if expand(IT, Common ^ sc_name, "hydrated_corr") then
        engine_intern("", Ref, !E),
        Value = str(Ref)
    else
        Value = null
    ).

%-----------------------------------------------------------------------------%

:- func array_member(json_members, string) = list(json).

array_member(Ms, Key) = Items :-
    ( if lookup_member(Ms, Key, Found), Found = j_array(Xs) then
        Items = Xs
    else
        Items = []
    ).

:- func string_array(list(json)) = list(string).

string_array(Items) =
    list.filter_map((func(J::in) = (S::out) is semidet :- J = j_string(S)),
        Items).

    % A count or a step from the fixture, so a Mercury `int`.
    %
:- pred int_member(json_members::in, string::in, int::out) is semidet.

int_member(Ms, Key, Value) :-
    lookup_member(Ms, Key, Found),
    Found = j_int(V),
    Value = int64.cast_to_int(V).

:- func from_bytes(list(uint8)) = bitmap.

from_bytes(Bs) = BM :-
    BM0 = bitmap.init(list.length(Bs) * 8),
    fill_bytes(0, Bs, BM0, BM).

:- pred fill_bytes(int::in, list(uint8)::in,
                   bitmap::bitmap_di, bitmap::bitmap_uo) is det.

fill_bytes(_, [], !BM).
fill_bytes(I, [B | Bs], !BM) :-
    bitmap.set_uint8(I, B, !BM),
    fill_bytes(I + 1, Bs, !BM).

%-----------------------------------------------------------------------------%
% The census, the work list and the verdict
%-----------------------------------------------------------------------------%

:- pred report(list(string)::in, list(maybe(fixture_row))::in,
               tally::in, tally::out, io::di, io::uo) is det.

report(Names, Results, !T, !IO) :-
    Full = list.filter_map(corresponding,
        list.map_corresponding(func(N, R) = N - R, Names, Results)),
    Unreadable = list.filter_map(unreadable,
        list.map_corresponding(func(N, R) = N - R, Names, Results)),
    ( Unreadable = [], ReadableOk = yes ; Unreadable = [_ | _], ReadableOk = no ),
    list.foldl(
        (pred(U::in, !.S::di, !:S::uo) is det :-
            io.format("    unreadable or malformed fixture: %s\n", [s(U)],
                !S)),
        Unreadable, !IO),
    check(string.format("every one of the %d behavioural fixtures is readable",
        [i(list.length(Names))]), ReadableOk, !T, !IO),

    Pairs = list.map(func(N - R) = N - R ^ fr_result ^ br_outcome, Full),
    io.format("  behavioural corpus (every category but compiler): %d fixtures\n",
        [i(list.length(Pairs))], !IO),
    list.foldl(report_count(Pairs), all_outcomes, !IO),

    report_rows("wrong behaviour",
        list.filter(
            ( pred(_ - R::in) is semidet :-
                R ^ fr_result ^ br_outcome = bo_fail,
                R ^ fr_result ^ br_detail \= no_callback_kind
            ), Full), !IO),
    report_rows("failing by design: no callback to leave unregistered",
        list.filter(
            ( pred(_ - R::in) is semidet :-
                R ^ fr_result ^ br_outcome = bo_fail,
                R ^ fr_result ^ br_detail = no_callback_kind
            ), Full), !IO),
    report_rows("the runtime's loader refused",
        list.filter(has_outcome(bo_load_failed), Full), !IO),
    report_rows("a step this driver does not model",
        list.filter(has_outcome(bo_unsupported), Full), !IO),
    histogram("why rules go unlowered",
        list.map(func(_ - R) = R ^ fr_result ^ br_detail,
            list.filter(has_outcome(bo_unlowered), Full)), !IO),
    histogram("failing: expectation kinds this driver does not evaluate",
        list.map(func(_ - R) = R ^ fr_result ^ br_kind,
            list.filter(
                ( pred(_ - R::in) is semidet :-
                    R ^ fr_result ^ br_outcome = bo_fail,
                    R ^ fr_result ^ br_detail = unevaluated_kind
                ), Full)), !IO),

    % Every fixture passes, or is deprecated ([RCTS.1.2.12]: kept, not run).
    % Any other outcome fails the gate.
    NotPassing = list.filter(
        ( pred(_ - R::in) is semidet :-
            O = R ^ fr_result ^ br_outcome,
            O \= bo_pass,
            O \= bo_deprecated
        ), Full),
    % Each is named from the set the check counts, which the rows above do
    % not cover.
    report_rows("every fixture that neither passes nor is deprecated",
        NotPassing, !IO),
    ( NotPassing = [], PassOk = yes ; NotPassing = [_ | _], PassOk = no ),
    check(string.format(
        "every behavioural fixture passes or is deprecated (%d do not)",
        [i(list.length(NotPassing))]), PassOk, !T, !IO).

:- func corresponding(pair(string, maybe(fixture_row)))
    = pair(string, fixture_row) is semidet.

corresponding(Name - yes(Row)) = Name - Row.

:- func unreadable(pair(string, maybe(fixture_row))) = string is semidet.

unreadable(Name - no) = Name.

:- pred has_outcome(outcome::in, pair(string, fixture_row)::in) is semidet.

has_outcome(Outcome, _ - Row) :-
    Row ^ fr_result ^ br_outcome = Outcome.

:- pred report_count(assoc_list(string, outcome)::in, outcome::in,
                     io::di, io::uo) is det.

report_count(Pairs, Outcome, !IO) :-
    N = list.length(list.filter((pred(_ - O::in) is semidet :- O = Outcome),
        Pairs)),
    ( if N > 0 then
        io.format("    %-14s %d\n", [s(outcome_name(Outcome)), i(N)], !IO)
    else
        true
    ).

    % Every fixture in the set, named, with its outcome and the detail.
    %
:- pred report_rows(string::in, assoc_list(string, fixture_row)::in,
                    io::di, io::uo) is det.

report_rows(Title, Rows, !IO) :-
    (
        Rows = []
    ;
        Rows = [_ | _],
        io.format("  %s (%d):\n", [s(Title), i(list.length(Rows))], !IO),
        list.foldl(
            (pred(N - R::in, !.S::di, !:S::uo) is det :-
                io.format("    %s  %s\n      %s\n",
                    [s(N), s(outcome_name(R ^ fr_result ^ br_outcome)),
                     s(R ^ fr_result ^ br_detail)], !S)),
            Rows, !IO)
    ).

:- pred histogram(string::in, list(string)::in, io::di, io::uo) is det.

histogram(Title, Items, !IO) :-
    (
        Items = []
    ;
        Items = [_ | _],
        list.foldl(count_item, Items, map.init, Counts),
        Rows = list.sort(list.map(func(Item - N) = (-N) - Item,
            map.to_assoc_list(Counts))),
        io.format("  %s (%d):\n", [s(Title), i(list.length(Items))], !IO),
        list.foldl(
            (pred(NegN - Item::in, !.S::di, !:S::uo) is det :-
                io.format("    %4d  %s\n", [i(-NegN), s(Item)], !S)),
            Rows, !IO)
    ).

:- pred count_item(string::in, map(string, int)::in, map(string, int)::out)
    is det.

count_item(Item, !Counts) :-
    ( if map.search(!.Counts, Item, N) then
        map.det_update(Item, N + 1, !Counts)
    else
        map.det_insert(Item, 1, !Counts)
    ).

%-----------------------------------------------------------------------------%
:- end_module test_behave.
%-----------------------------------------------------------------------------%

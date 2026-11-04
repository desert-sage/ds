%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: host_values_mercury.m.
%
% fuzz_host_values's op scripts through mercury_ds.
%
%   host_values_mercury PROGRAM.dsc DIR [DIR ...]
%   host_values_mercury --self-test
%
% runtime/tests/fuzz/fuzz_host_values.c hands libds.h the values a host
% asserts, and runtime/tests/fuzz/host_values_pyds.py hands pyds the same
% scripts. This hands them to the Mercury binding, which drives the Mercury
% runtime, and holds the run to the same checks in Mercury's terms. Every
% regular file in each DIR is one input, in name order, one session each, on
% the mock clock with the wall clock set. gate.py's `_fuzz_bindings` runs
% it, linked as a host of the two installed libraries
% (scripts/mercury/check.py's `link_hosts`).
%
% THE SCRIPT is fuzz_host_values.c's, read the same way: an op byte taken
% modulo eight (ASSERT, PUMP, ADVANCE, WALL, SEED, WHEN, ZONE, IDS) and its
% operands, and a script that runs out of bytes mid-op stops there. Its
% values become the binding's:
%
%   id   the byte modulo 8, an `int`
%   s, u the octets as a Mercury string, which holds them as they are, so
%        octets that are not well-formed UTF-8 reach the binding as they
%        reach libds. A NUL, which no Mercury string holds, means the host
%        cannot make the value, and nothing is asserted
%   i    an `int`; f a `float` from its bits, a NaN as a NaN; ok a `bool`
%   b    `bytes`
%   j    the octets as JSON text through the binding's `json_from_text`, or
%        JSON null where it refuses the text, as fuzz_host_values.c reads
%        it through ds_json_parse
%   SEED the key as `s` is made, the value as `j` is, and no TTL
%   WHEN a When: id as above, t and d `int`s, z made as `s` is
%   ZONE a TimeZoneOffset: zone made as `s` is, the three others `int`s
%   IDS  a session loaded with the run and tier id, each made as `s` is,
%        replaces the one the script has run so far; refused, that one stays
%
% WHAT IT ASSERTS, each a finding that ends the run with exit 1:
%
%   1. EVERY REFUSAL IS ONE THE BINDING DOCUMENTS: the status libds.h names
%      for the same call. `json_from_text` answers what libds's
%      ds_json_parse answers, which it says it reads as.
%   2. ILL-FORMED TEXT IS NEVER TAKEN ([LSTR.8.5], [LSTR.1.1]). An assert
%      whose `s` or `u`, a When's `z` or a row's `zone` is not well-formed
%      UTF-8 is refused, and so is a seed whose key is not, and a session
%      whose run or tier id is not ([NLFC.1.2]). `json_from_text` refuses
%      text that is not with `encoding`, checked whole before it parses any
%      of it, after the text limit alone (`json_limit`).
%   3. NO HOST VALUE HALTS THE ENGINE. A pump that answers `engine_halted`
%      is a finding, named with the EngineError the stream carried.
%   4. WHAT LEAVES THE ENGINE IS WELL-FORMED. Every log message, String call
%      argument, cache key and cache value is well-formed UTF-8 with no NUL,
%      and every Json value is JSON text the binding reads.
%   5. A CALL IS THE ONE DECLARED: `sink.take`, its arguments sorted by
%      name, each of the kind its kwarg declares, and no NaN.
%
% Its reference for well-formed UTF-8 is its own (`well_formed`), not the
% runtime's, which is under test.
%
% At exit it prints its counts, which the gate reads: every input judged,
% and an assert, a pump, a log, a call, a cache write, a When, a zone row, a
% session with ids and a refused ill-formed text each seen at least once over
% the seeds.
%
%---------------------------------------------------------------------------%

:- module host_values_mercury.
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
:- import_module mercury_ds.session.
:- import_module mercury_ds.status.
:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.fact_external.
:- import_module ds.json.
:- import_module bitmap.
:- import_module bool.
:- import_module cord.
:- import_module dir.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module string.
:- import_module uint64.

    % Qualified: only its `float_from_bits` is wanted here.
    %
:- use_module ds.wire.

%---------------------------------------------------------------------------%

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    io.stdout_stream(Stdout, !IO),
    io.stderr_stream(Stderr, !IO),
    ( if Args = ["--self-test"] then
        Bad = self_test,
        list.foldl(put_line(Stderr, "host_values_mercury: self-test: "),
            Bad, !IO),
        (
            Bad = [],
            put_line(Stdout, "host_values_mercury: self-test: ", "ok", !IO)
        ;
            Bad = [_ | _],
            put_line(Stdout, "host_values_mercury: self-test: ", "FAILED",
                !IO),
            io.set_exit_status(1, !IO)
        )
    else if Args = [ProgramPath, Dir | Dirs] then
        read_bytes(ProgramPath, ReadProgram, !IO),
        (
            ReadProgram = error(Why),
            put_line(Stderr, "host_values_mercury: ", Why, !IO),
            io.set_exit_status(1, !IO)
        ;
            ReadProgram = ok(Program),
            judge_dirs(Program, [Dir | Dirs], zero_tally, Judged, !IO),
            (
                Judged = judged(Tally),
                put_line(Stdout, "", summary(Tally), !IO)
            ;
                Judged = found(Path, Input, Findings),
                put_line(Stderr, "host_values_mercury: ",
                    Path ++ ": " ++ hex(Input), !IO),
                list.foldl(put_line(Stderr, "host_values_mercury: "),
                    Findings, !IO),
                io.set_exit_status(1, !IO)
            ;
                Judged = stopped(Why),
                put_line(Stderr, "host_values_mercury: ", Why, !IO),
                io.set_exit_status(1, !IO)
            )
        )
    else
        put_line(Stderr, "usage: ", "host_values_mercury PROGRAM.dsc "
            ++ "DIR [DIR ...] | host_values_mercury --self-test", !IO),
        io.set_exit_status(2, !IO)
    ).

:- pred put_line(io.text_output_stream::in, string::in, string::in,
    io::di, io::uo) is det.

put_line(Stream, Prefix, Line, !IO) :-
    io.write_string(Stream, Prefix ++ Line ++ "\n", !IO).

    % The counts line the gate reads (gate.py `_binding_judged_all`).
    %
:- func summary(tally) = string.

summary(T) = string.format("host_values_mercury: judged %d input(s): "
    ++ "%d asserted, %d pumped, %d logged, %d called, %d cached, "
    ++ "%d timed, %d zoned, %d named, %d ill-formed refused",
    [i(T ^ t_judged), i(T ^ t_asserted), i(T ^ t_pumped), i(T ^ t_logged),
     i(T ^ t_called), i(T ^ t_cached), i(T ^ t_timed), i(T ^ t_zoned),
     i(T ^ t_named), i(T ^ t_ill)]).

%---------------------------------------------------------------------------%
% The inputs
%---------------------------------------------------------------------------%

:- type judged
    --->    judged(tally)
            % Every input judged, and nothing found.
    ;       found(string, list(int), list(string))
            % The input with a finding: its path, its octets, the findings.
    ;       stopped(string).
            % A file this driver could not read.

:- type tally
    --->    tally(
                t_judged    :: int,
                t_asserted  :: int,
                t_pumped    :: int,
                t_logged    :: int,
                t_called    :: int,
                t_cached    :: int,
                t_timed     :: int,
                            % When facts asserted.
                t_zoned     :: int,
                            % TimeZoneOffset rows asserted.
                t_named     :: int,
                            % Sessions an IDS loaded with its ids.
                t_ill       :: int
                            % Asserts, and sessions, refused whose text
                            % was not well-formed UTF-8.
            ).

:- func zero_tally = tally.

zero_tally = tally(0, 0, 0, 0, 0, 0, 0, 0, 0, 0).

:- pred judge_dirs(bitmap::in, list(string)::in, tally::in, judged::out,
    io::di, io::uo) is det.

judge_dirs(_, [], Tally, judged(Tally), !IO).
judge_dirs(Program, [Dir | Dirs], Tally0, Judged, !IO) :-
    dir.foldl2(add_file, Dir, [], Listed, !IO),
    (
        Listed = ok(Paths),
        judge_files(Program, list.sort(Paths), Tally0, Judged0, !IO),
        ( if Judged0 = judged(Tally) then
            judge_dirs(Program, Dirs, Tally, Judged, !IO)
        else
            Judged = Judged0
        )
    ;
        Listed = error(_, Error),
        Judged = stopped(Dir ++ ": " ++ io.error_message(Error))
    ).

:- pred add_file(string::in, string::in, io.file_type::in, bool::out,
    list(string)::in, list(string)::out, io::di, io::uo) is det.

add_file(DirName, BaseName, FileType, yes, !Paths, !IO) :-
    ( if FileType = regular_file then
        !:Paths = [DirName ++ "/" ++ BaseName | !.Paths]
    else
        true
    ).

:- pred judge_files(bitmap::in, list(string)::in, tally::in, judged::out,
    io::di, io::uo) is det.

judge_files(_, [], Tally, judged(Tally), !IO).
judge_files(Program, [Path | Paths], Tally0, Judged, !IO) :-
    read_bytes(Path, Read, !IO),
    (
        Read = error(Why),
        Judged = stopped(Why)
    ;
        Read = ok(Bitmap),
        Input = bitmap_bytes(Bitmap),
        (
            Input = [],
            judge_files(Program, Paths, Tally0, Judged, !IO)
        ;
            Input = [_ | _],
            Ran = judge(Program, Input, Tally0),
            (
                Ran = ok(Tally),
                judge_files(Program, Paths, Tally, Judged, !IO)
            ;
                Ran = error(Findings),
                Judged = found(Path, Input, Findings)
            )
        )
    ).

%---------------------------------------------------------------------------%
% One input
%---------------------------------------------------------------------------%

    % One session's run over one script.
    %
:- type run
    --->    run(
                run_program  :: bitmap,
                            % The artefact, which an IDS loads again.
                run_session  :: session,
                run_tally    :: tally,
                run_findings :: cord(string),
                run_halts    :: list(string)
                            % What each EngineError the stream carried
                            % said, for a halt's finding.
            ).

    % Load the program on the mock clock, set the wall clock, run the
    % script, and pump once more, as fuzz_host_values.c does. The tally
    % with this input's counts added, or what it found.
    %
:- func judge(bitmap, list(int), tally) = maybe_error(tally, list(string)).

judge(Program, Input, Tally0) = Result :-
    load(Program, default_config, Loaded, _),
    (
        Loaded = error(Error),
        Result = error(["the program did not load: " ++ error_text(Error)])
    ;
        Loaded = ok(Session0),
        set_wall_clock(wall_ns, Wall, Session0, Session),
        Tally = Tally0 ^ t_judged := Tally0 ^ t_judged + 1,
        Run0 = wall_checked(Wall,
            run(Program, Session, Tally, cord.empty, [])),
        script(Input, Run0, Run1),
        Run = pump_once(Run1),
        Findings = cord.list(Run ^ run_findings),
        (
            Findings = [],
            Result = ok(Run ^ run_tally)
        ;
            Findings = [_ | _],
            Result = error(Findings)
        )
    ).

:- func wall_ns = int64.

wall_ns = 1700000000000000000i64.

:- func ops = int.
:- func op_assert = int.
:- func op_pump = int.
:- func op_advance = int.
:- func op_wall = int.
:- func op_seed = int.
:- func op_when = int.
:- func op_zone = int.

ops = 8.
op_assert = 0.
op_pump = 1.
op_advance = 2.
op_wall = 3.
op_seed = 4.
op_when = 5.
op_zone = 6.

    % The script's ops in order; the eighth, IDS, is what is left.
    %
:- pred script(list(int)::in, run::in, run::out) is det.

script(Bytes0, !Run) :-
    ( if Bytes0 = [Op | Bytes1] then
        Code = Op mod ops,
        ( if Code = op_assert then
            ( if read_assert(Bytes1, Operands, Bytes) then
                !:Run = host_assert(Operands, !.Run),
                script(Bytes, !Run)
            else
                true
            )
        else if Code = op_pump then
            !:Run = pump_once(!.Run),
            script(Bytes1, !Run)
        else if Code = op_advance then
            ( if list.split_list(4, Bytes1, Us, Bytes) then
                !:Run = host_advance(le_uint64(Us), !.Run),
                script(Bytes, !Run)
            else
                true
            )
        else if Code = op_wall then
            ( if list.split_list(8, Bytes1, Utc, Bytes) then
                set_wall_clock(int64.cast_from_uint64(le_uint64(Utc)), Wall,
                    !.Run ^ run_session, Session),
                !:Run = wall_checked(Wall, (!.Run ^ run_session := Session)),
                script(Bytes, !Run)
            else
                true
            )
        else if Code = op_seed then
            ( if
                take_str(Bytes1, Key, Bytes2),
                take_str(Bytes2, Value, Bytes)
            then
                !:Run = host_seed(Key, Value, !.Run),
                script(Bytes, !Run)
            else
                true
            )
        else if Code = op_when then
            ( if
                Bytes1 = [Id | Bytes2],
                list.split_list(8, Bytes2, T, Bytes3),
                list.split_list(8, Bytes3, D, Bytes4),
                take_str(Bytes4, Z, Bytes)
            then
                !:Run = host_when(Id, T, D, Z, !.Run),
                script(Bytes, !Run)
            else
                true
            )
        else if Code = op_zone then
            ( if
                take_str(Bytes1, Name, Bytes2),
                list.split_list(8, Bytes2, From, Bytes3),
                list.split_list(8, Bytes3, Until, Bytes4),
                list.split_list(8, Bytes4, Offset, Bytes)
            then
                !:Run = host_zone(Name, From, Until, Offset, !.Run),
                script(Bytes, !Run)
            else
                true
            )
        else
            ( if
                take_str(Bytes1, RunId, Bytes2),
                take_str(Bytes2, TierId, Bytes)
            then
                !:Run = host_ids(RunId, TierId, !.Run),
                script(Bytes, !Run)
            else
                true
            )
        )
    else
        true
    ).

    % Octets as a signed 64-bit integer, the first the least significant.
    %
:- func le_int64(list(int)) = int64.

le_int64(Bytes) = int64.cast_from_uint64(le_uint64(Bytes)).

    % An ASSERT's operands: id, s, u, i (8 octets), f (8 octets), ok, b, j.
    %
:- type assert_operands
    --->    assert_operands(int, list(int), list(int), list(int), list(int),
                int, list(int), list(int)).

:- pred read_assert(list(int)::in, assert_operands::out, list(int)::out)
    is semidet.

read_assert(Bytes0, Operands, Bytes) :-
    Bytes0 = [Id | Bytes1],
    take_str(Bytes1, S, Bytes2),
    take_str(Bytes2, U, Bytes3),
    list.split_list(8, Bytes3, I, Bytes4),
    list.split_list(8, Bytes4, F, Bytes5),
    Bytes5 = [Ok | Bytes6],
    take_str(Bytes6, B, Bytes7),
    take_str(Bytes7, J, Bytes),
    Operands = assert_operands(Id, S, U, I, F, Ok, B, J).

    % A `str` operand: a 16-bit length, little-endian, and that many octets.
    %
:- pred take_str(list(int)::in, list(int)::out, list(int)::out) is semidet.

take_str([Lo, Hi | Bytes], Str, Rest) :-
    list.split_list(Lo + Hi * 256, Bytes, Str, Rest).

    % Octets as an unsigned integer, the first the least significant.
    %
:- func le_uint64(list(int)) = uint64.

le_uint64(Bytes) = list.foldr(
    (func(B, Acc) = (Acc << 8) \/ uint64.cast_from_int(B)), Bytes, 0u64).

    % A binary64 from its bits. `ds.wire.float_from_bits` reads a NaN as
    % 0.0, so a NaN's bits are made a NaN here: the binding must refuse it.
    %
:- func float_of_bits(uint64) = float.

float_of_bits(Bits) =
    ( if nan_bits(Bits) then
        a_nan
    else
        ds.wire.float_from_bits(Bits)
    ).

:- pred nan_bits(uint64::in) is semidet.

nan_bits(Bits) :-
    (Bits >> 52) /\ 0x7FFu64 = 0x7FFu64,
    Bits /\ 0xFFFFFFFFFFFFFu64 \= 0u64.

%---------------------------------------------------------------------------%
% The ops
%---------------------------------------------------------------------------%

:- func host_assert(assert_operands, run) = run.

host_assert(assert_operands(Id, S, U, I, F, Ok, B, J), Run0) = Run :-
    json_of_octets(J, Json, JsonProblems),
    Run1 = list.foldl(finding, JsonProblems, Run0),
    ( if
        octets_text(S) = yes(SText),
        octets_text(U) = yes(UText)
    then
        Values = slot_values(Id, SText, UText, I, F, Ok, B, Json),
        Ill = ( if well_formed(S), well_formed(U) then no else yes ),
        Run = assert_judged("Host", Values, Ill, bump_asserted, Run1)
    else
        % A NUL in `s` or `u`, which no Mercury string holds: the host
        % cannot make the value, so nothing is asserted, as pyds refuses
        % one with ValueError before libds sees it.
        Run = Run1
    ).

    % Assert one fact, judged as an ASSERT is: a status ds_engine_assert
    % names, and ill-formed text never taken. `Bump` adds an accepted one to
    % its count.
    %
:- func assert_judged(string, list(storable), bool, (func(run) = run), run)
    = run.

assert_judged(Schema, Values, Ill, Bump, Run0) = Run :-
    assert_fact(Schema, Values, Step, Run0 ^ run_session, Session),
    Run1 = after(Step ^ assert_step_reports, Step ^ assert_step_duties,
        (Run0 ^ run_session := Session)),
    Outcome = Step ^ assert_step_outcome,
    ( if Outcome = error(Error) then
        error_status(Error, Status),
        ( if list.member(Status, assert_statuses) then
            Run2 = Run1
        else
            Run2 = finding("assert_fact " ++ Schema ++ " answered a status "
                ++ "libds.h does not name for ds_engine_assert: "
                ++ error_text(Error), Run1)
        ),
        Run = ( if Ill = yes then bump_ill(Run2) else Run2 )
    else
        Run2 = Bump(Run1),
        ( if Ill = yes then
            Run = finding("ill-formed text was taken by " ++ Schema, Run2)
        else
            Run = Run2
        )
    ).

    % A When: its id, a Time, a Date's day count and a zone designation.
    %
:- func host_when(int, list(int), list(int), list(int), run) = run.

host_when(Id, T, D, Z, Run0) = Run :-
    ( if octets_text(Z) = yes(ZText) then
        Values = [int(int64.from_int(Id mod 8)), int(le_int64(T)),
            int(le_int64(D)), text(ZText)],
        Ill = ( if well_formed(Z) then no else yes ),
        Run = assert_judged("When", Values, Ill, bump_timed, Run0)
    else
        % A NUL, which no Mercury string holds.
        Run = Run0
    ).

    % A TimeZoneOffset row ([LTIM.10.6]), its slots in declaration order.
    %
:- func host_zone(list(int), list(int), list(int), list(int), run) = run.

host_zone(Name, From, Until, Offset, Run0) = Run :-
    ( if octets_text(Name) = yes(NameText) then
        Values = [text(NameText), int(le_int64(From)), int(le_int64(Until)),
            int(le_int64(Offset))],
        Ill = ( if well_formed(Name) then no else yes ),
        Run = assert_judged("TimeZoneOffset", Values, Ill, bump_zoned, Run0)
    else
        Run = Run0
    ).

    % A session loaded with this run and tier id replaces the one the
    % script has run so far, which is pumped once more; one the load refuses
    % leaves it in place. The load answers `encoding` for an id that is not
    % well-formed UTF-8 ([NLFC.1.2]), as ds_engine_new does.
    %
:- func host_ids(list(int), list(int), run) = run.

host_ids(RunId, TierId, Run0) = Run :-
    ( if
        octets_text(RunId) = yes(RunText),
        octets_text(TierId) = yes(TierText)
    then
        Ill = ( if well_formed(RunId), well_formed(TierId) then no else yes ),
        Config = (default_config
            ^ session_config_run_id := yes(RunText))
            ^ session_config_tier_id := yes(TierText),
        load(Run0 ^ run_program, Config, Loaded, _),
        (
            Loaded = error(Error),
            error_status(Error, Status),
            ( if Status = encoding then
                Run1 = Run0
            else
                Run1 = finding("load answered a status libds.h does not "
                    ++ "name for ds_engine_new: " ++ error_text(Error), Run0)
            ),
            Run = ( if Ill = yes then bump_ill(Run1) else Run1 )
        ;
            Loaded = ok(Session0),
            set_wall_clock(wall_ns, Wall, Session0, Session),
            Run1 = pump_once(Run0),
            Run2 = bump_named(wall_checked(Wall,
                (Run1 ^ run_session := Session))),
            ( if Ill = yes then
                Run = finding("ill-formed text was taken as an engine id: "
                    ++ hex(RunId) ++ " " ++ hex(TierId), Run2)
            else
                Run = Run2
            )
        )
    else
        % A NUL, which no Mercury string holds.
        Run = Run0
    ).

    % The Host schema's slots, in declaration order.
    %
:- func slot_values(int, string, string, list(int), list(int), int,
    list(int), json) = list(storable).

slot_values(Id, S, U, I, F, Ok, B, Json) =
    [int(int64.from_int(Id mod 8)), text(S), text(U),
     int(int64.cast_from_uint64(le_uint64(I))),
     float(float_of_bits(le_uint64(F))),
     bool(( if Ok /\ 1 = 1 then yes else no )),
     bytes(bytes_bitmap(B)), json(Json)].

:- func pump_once(run) = run.

pump_once(Run0) = Run :-
    pump(Pumped, Run0 ^ run_session, Session),
    Run1 = bump_pumped((Run0 ^ run_session := Session)),
    Run2 = after(Pumped ^ pumped_reports, Pumped ^ pumped_duties, Run1),
    Run3 = list.foldl(on_call, Pumped ^ pumped_calls, Run2),
    Outcome = Pumped ^ pumped_outcome,
    (
        Outcome = ok,
        Run = Run3
    ;
        Outcome = error(Error),
        error_status(Error, Status),
        ( if Status = engine_halted then
            Run = finding("a host value halted the engine: "
                ++ string.join_list("; ", Run3 ^ run_halts) ++ " "
                ++ error_text(Error), Run3)
        else if Status = contract_breach then
            Run = Run3
        else
            Run = finding("pump answered a status libds.h does not name "
                ++ "for ds_engine_pump: " ++ error_text(Error), Run3)
        )
    ).

    % fuzz_host_values.c fails on the same refusal.
    %
:- func wall_checked(outcome, run) = run.

wall_checked(ok, Run) = Run.
wall_checked(error(Error), Run) =
    finding("set_wall_clock refused on the mock clock: "
        ++ error_text(Error), Run).

:- func host_advance(uint64, run) = run.

host_advance(Us, Run0) = Run :-
    advance(duration_from_ns(Us * 1000u64), Step, Run0 ^ run_session,
        Session),
    Run1 = after(Step ^ step_reports, Step ^ step_duties,
        (Run0 ^ run_session := Session)),
    ( if
        Step ^ step_outcome = error(Error),
        % [NTST.3.1]: past the wall clock's range is refused.
        not error_status(Error, time_range)
    then
        Run = finding("advance refused on the mock clock: "
            ++ error_text(Error), Run1)
    else
        Run = Run1
    ).

:- func host_seed(list(int), list(int), run) = run.

host_seed(KeyOctets, ValueOctets, Run0) = Run :-
    json_of_octets(ValueOctets, Json, JsonProblems),
    Run1 = list.foldl(finding, JsonProblems, Run0),
    MaybeKey = octets_text(KeyOctets),
    (
        % A key no Mercury string holds: nothing to seed.
        MaybeKey = no,
        Run = Run1
    ;
        MaybeKey = yes(Key),
        cache_seed(Key, Json, no, Outcome, Run1 ^ run_session, Session),
        Run2 = Run1 ^ run_session := Session,
        (
            Outcome = ok,
            ( if well_formed(KeyOctets) then
                Run = Run2
            else
                Run = finding("cache_seed took a key that is not "
                    ++ "well-formed UTF-8: " ++ hex(KeyOctets), Run2)
            )
        ;
            Outcome = error(Error),
            error_status(Error, Status),
            ( if list.member(Status, seed_statuses) then
                Run = Run2
            else
                Run = finding("cache_seed answered a status libds.h does "
                    ++ "not name for ds_engine_cache_seed: "
                    ++ error_text(Error), Run2)
            )
        )
    ).

    % The statuses each call may answer with, as fuzz_host_values.c's
    % `assert_documented` and `seed_documented` list them, and the two a
    % Json value built from text adds to an assert, as host_values_pyds.py
    % lists them; a seed's value adds a refusal of its text, `parse`.
    %
:- func assert_statuses = list(status).

assert_statuses = [inval, slot_type_mismatch, encoding, time_range,
    nan_rejected, contract_breach, json_nonfinite, json_limit].

:- func seed_statuses = list(status).

seed_statuses = [state, encoding, contract_breach, time_range,
    json_nonfinite, parse, json_limit].

    % What ds_json_parse answers for text it refuses.
    %
:- func json_text_statuses = list(status).

json_text_statuses = [parse, json_limit, encoding].

%---------------------------------------------------------------------------%
% What a call reports
%---------------------------------------------------------------------------%

:- func after(list(report), list(duty), run) = run.

after(Reports, Duties, Run) =
    list.foldl(on_duty, Duties, list.foldl(on_report, Reports, Run)).

:- func on_report(report, run) = run.

on_report(streamed(Event), Run0) = Run :-
    ( if Event ^ integrator_event_kind = engine_error(Fault, Info) then
        Run = Run0 ^ run_halts := [string.string(Fault) ++ " in "
            ++ Info ^ fault_info_rule | Run0 ^ run_halts]
    else
        Run = Run0
    ).
on_report(logged(log_line(_, _, Message)), Run) =
    list.foldl(finding, text_problems(Message, "a log message"),
        bump_logged(Run)).
on_report(measured(_), Run) = Run.
on_report(cache_expired(_), Run) = Run.

:- func on_duty(duty, run) = run.

on_duty(write_cache(cache_write(Key, ValueJson, _)), Run0) = Run :-
    ( if ( Key = "s" ; Key = "j" ) then
        Problems = []
    else
        Problems = ["a rule wrote a cache key the program does not "
            ++ "write: " ++ Key]
    ),
    Run = list.foldl(finding,
        Problems ++ json_text_problems(ValueJson, "a cache value"),
        bump_cached(Run0)).
on_duty(remove_cache(_), Run) = Run.

:- func on_call(service_call, run) = run.

on_call(Call, Run) =
    list.foldl(finding,
        call_problems(Call ^ service_call_service,
            Call ^ service_call_correlation, Call ^ service_call_args),
        bump_called(Run)).

:- func call_problems(string, string, list(arg)) = list(string).

call_problems(Service, Correlation, Args) =
    ( if Service = "sink.take" then
        []
    else
        ["a call names a service the program does not call: " ++ Service]
    ) ++
    ( if Correlation = "" then ["a call has no correlation"] else [] ) ++
    arg_problems(Args).

    % sink.take's kwargs, sorted by name.
    %
:- func kwargs = list(string).

kwargs = ["b", "f", "i", "j", "s"].

:- func arg_problems(list(arg)) = list(string).

arg_problems(Args) = Problems :-
    Names = list.map(name_of, Args),
    ( if Names = kwargs then
        Problems = list.condense(list.map(arg_value_problems, Args))
    else
        Problems = ["a call's arguments are not its kwargs, sorted by "
            ++ "name: " ++ string.join_list(",", Names)]
    ).

    % An argument's name. (A field's access function is no closure.)
    %
:- func name_of(arg) = string.

name_of(arg(Name, _)) = Name.

:- func arg_value_problems(arg) = list(string).

arg_value_problems(arg(Name, Value)) = Problems :-
    ( if Name = "b", Value = av_bytes(_) then
        Problems = []
    else if Name = "f", Value = av_float(F) then
        Problems = ( if float.is_nan(F)
                     then ["a NaN reached call argument f"] else [] )
    else if Name = "i", Value = av_int(_) then
        Problems = []
    else if Name = "j", Value = av_json(Text) then
        Problems = json_text_problems(Text, "call argument j")
    else if Name = "s", Value = av_string(Text) then
        Problems = text_problems(Text, "call argument s")
    else
        Problems = ["call argument " ++ Name
            ++ " is not the kind its kwarg declares"]
    ).

:- func text_problems(string, string) = list(string).

text_problems(Text, What) = Problems :-
    string.to_code_unit_list(Text, Units),
    ( if well_formed(Units) then
        Problems = []
    else
        Problems = [What ++ " is not well-formed UTF-8: " ++ hex(Units)]
    ).

:- func json_text_problems(string, string) = list(string).

json_text_problems(Text, What) = text_problems(Text, What) ++
    ( if json_from_text(Text) = ok(_) then
        []
    else
        [What ++ " is not JSON text: " ++ Text]
    ).

%---------------------------------------------------------------------------%
% Text
%---------------------------------------------------------------------------%

    % The octets as a Mercury string, which holds them as they are, or `no`
    % for octets with a NUL, which no Mercury string holds.
    %
:- func octets_text(list(int)) = maybe(string).

octets_text(Octets) = Text :-
    ( if
        not list.member(0, Octets),
        string.from_code_unit_list_allow_ill_formed(Octets, Text0)
    then
        Text = yes(Text0)
    else
        Text = no
    ).

    % `j`'s octets as fuzz_host_values.c reads them: the Json value their
    % text is, through the binding's reader, or JSON null where it refuses
    % them, with what the reader's answer breaks.
    %
:- pred json_of_octets(list(int)::in, json::out, list(string)::out) is det.

json_of_octets(Octets, Json, Problems) :-
    MaybeText = octets_text(Octets),
    (
        MaybeText = no,
        Json = j_null,
        Problems = []
    ;
        MaybeText = yes(Text),
        Read = json_from_text(Text),
        (
            Read = ok(Json),
            ( if well_formed(Octets) then
                Problems = []
            else
                Problems = ["json_from_text took text that is not "
                    ++ "well-formed UTF-8: " ++ hex(Octets)]
            )
        ;
            Read = error(Error),
            Json = j_null,
            error_status(Error, Status),
            Problems = text_refusal_problems(Octets, Status)
        )
    ).

    % What a refusal of JSON text breaks: a status ds_json_parse does not
    % answer, or, for text that is not well-formed UTF-8, any status but
    % `encoding`, or `json_limit` for text past the text limit, which
    % [LSTR.8.5] checks first.
    %
:- func text_refusal_problems(list(int), status) = list(string).

text_refusal_problems(Octets, Status) = Problems :-
    ( if not list.member(Status, json_text_statuses) then
        Problems = ["json_from_text answered a status ds_json_parse does "
            ++ "not: " ++ status_name(Status)]
    else if
        not well_formed(Octets),
        ( if list.length(Octets) > max_text_bytes then
            Want = json_limit
        else
            Want = encoding
        ),
        Status \= Want
    then
        Problems = ["json_from_text refused text that is not well-formed "
            ++ "UTF-8 with " ++ status_name(Status) ++ ", not "
            ++ status_name(Want) ++ ": " ++ hex(Octets)]
    else
        Problems = []
    ).

    % RFC 3629: no overlong form, no surrogate, nothing above U+10FFFF, no
    % sequence cut short, and no NUL, as fuzz_host_values.c's `well_formed`.
    %
:- pred well_formed(list(int)::in) is semidet.

well_formed([]).
well_formed([C | Cs]) :-
    C \= 0,
    ( if C < 0x80 then
        well_formed(Cs)
    else
        ( if C >= 0xc2, C =< 0xdf then
            K = 1,
            Cp0 = C /\ 0x1f
        else if C >= 0xe0, C =< 0xef then
            K = 2,
            Cp0 = C /\ 0x0f
        else if C >= 0xf0, C =< 0xf4 then
            K = 3,
            Cp0 = C /\ 0x07
        else
            fail
        ),
        list.split_list(K, Cs, Tail, Rest),
        list.foldl(continuation, Tail, Cp0, Cp),
        not ( K = 2, Cp < 0x800 ),
        not ( K = 3, Cp < 0x10000 ),
        not ( Cp >= 0xd800, Cp =< 0xdfff ),
        Cp =< 0x10ffff,
        well_formed(Rest)
    ).

:- pred continuation(int::in, int::in, int::out) is semidet.

continuation(T, Cp0, Cp) :-
    T /\ 0xc0 = 0x80,
    Cp = (Cp0 << 6) \/ (T /\ 0x3f).

%---------------------------------------------------------------------------%
% The run's record
%---------------------------------------------------------------------------%

:- func finding(string, run) = run.

finding(Why, Run) = Run ^ run_findings := cord.snoc(Run ^ run_findings, Why).

:- func bump_asserted(run) = run.
:- func bump_pumped(run) = run.
:- func bump_logged(run) = run.
:- func bump_called(run) = run.
:- func bump_cached(run) = run.
:- func bump_timed(run) = run.
:- func bump_zoned(run) = run.
:- func bump_named(run) = run.
:- func bump_ill(run) = run.

bump_asserted(R) = R ^ run_tally ^ t_asserted :=
    R ^ run_tally ^ t_asserted + 1.
bump_pumped(R) = R ^ run_tally ^ t_pumped := R ^ run_tally ^ t_pumped + 1.
bump_logged(R) = R ^ run_tally ^ t_logged := R ^ run_tally ^ t_logged + 1.
bump_called(R) = R ^ run_tally ^ t_called := R ^ run_tally ^ t_called + 1.
bump_cached(R) = R ^ run_tally ^ t_cached := R ^ run_tally ^ t_cached + 1.
bump_timed(R) = R ^ run_tally ^ t_timed := R ^ run_tally ^ t_timed + 1.
bump_zoned(R) = R ^ run_tally ^ t_zoned := R ^ run_tally ^ t_zoned + 1.
bump_named(R) = R ^ run_tally ^ t_named := R ^ run_tally ^ t_named + 1.
bump_ill(R) = R ^ run_tally ^ t_ill := R ^ run_tally ^ t_ill + 1.

:- func error_text(ds_error) = string.

error_text(status_error(Status, Detail)) =
    string.format("[%d %s] %s",
        [i(status_number(Status)), s(status_name(Status)), s(Detail)]).

:- func hex(list(int)) = string.

hex(Bytes) = string.append_list(list.map(
    (func(B) = string.format("%02x", [i(B)])), Bytes)).

%---------------------------------------------------------------------------%
% The driver's own checks
%---------------------------------------------------------------------------%

    % Each of the checks above, fed what it must refuse and what it must
    % take: the gate runs this before the scripts, so a check that stopped
    % refusing fails the run rather than passing it. What did not hold.
    %
:- func self_test = list(string).

self_test = list.filter_map(
    (func(Check) = What is semidet :- Check = {no, What}), checks).

:- func checks = list({bool, string}).

    % Each check: whether it held, and what it means that it did not.
    %
checks = [
    { ( if well_formed([0x6f, 0x6b, 0xc3, 0xa9, 0xf0, 0x9f, 0x98, 0x80])
        then yes else no ), "well_formed refuses well-formed text" },
    { ( if well_formed([0x61, 0xff]) then no else yes ),
        "well_formed takes a stray 0xff" },
    { ( if well_formed([0xc0, 0x80]) then no else yes ),
        "well_formed takes an overlong" },
    { ( if well_formed([0xed, 0xa0, 0x80]) then no else yes ),
        "well_formed takes an encoded surrogate" },
    { ( if well_formed([0xe2, 0x82]) then no else yes ),
        "well_formed takes a cut sequence" },
    { ( if well_formed([0xf4, 0x90, 0x80, 0x80]) then no else yes ),
        "well_formed takes a code point above U+10FFFF" },
    { ( if well_formed([0x61, 0x00]) then no else yes ),
        "well_formed takes a NUL" },
    { ( if octets_text([0x61, 0x00]) = no then yes else no ),
        "octets_text makes a string with a NUL" },
    { ( if
            octets_text([0x61, 0xff]) = yes(Stray),
            string.to_code_unit_list(Stray, [0x61, 0xff])
        then yes else no ),
        "octets_text does not keep the octets as they are" },
    { ( if text_refusal_problems([0x61, 0xff], parse) = [_ | _]
        then yes else no ),
        "ill-formed text refused with parse is taken" },
    { ( if text_refusal_problems([0x61, 0xff], encoding) = []
        then yes else no ),
        "ill-formed text refused with encoding is a finding" },
    { ( if text_refusal_problems([0x7b], parse) = [] then yes else no ),
        "well-formed text refused with parse is a finding" },
    { ( if text_refusal_problems([0x7b], inval) = [_ | _]
        then yes else no ),
        "a refusal of text with inval is taken" },
    { ( if text_refusal_problems(long_ill_formed, encoding) = [_ | _]
        then yes else no ),
        "ill-formed text past the text limit refused with encoding is "
        ++ "taken" },
    { ( if text_refusal_problems(long_ill_formed, json_limit) = []
        then yes else no ),
        "ill-formed text past the text limit refused with json_limit is "
        ++ "a finding" },
    { ( if arg_problems(good_args) = [] then yes else no ),
        "a call's good arguments are a finding" },
    { ( if arg_problems(list.reverse(good_args)) = [_ | _]
        then yes else no ),
        "arguments out of order are taken" },
    { ( if arg_problems(with_arg(arg("f", av_float(a_nan)))) = [_ | _]
        then yes else no ),
        "a NaN call argument is taken" },
    { ( if arg_problems(with_arg(arg("j", av_json("{")))) = [_ | _]
        then yes else no ),
        "a Json call argument that is not JSON text is taken" },
    { ( if arg_problems(with_arg(arg("s", av_string(stray_text))))
            = [_ | _]
        then yes else no ),
        "an ill-formed String call argument is taken" },
    { ( if arg_problems(with_arg(arg("i", av_float(1.0)))) = [_ | _]
        then yes else no ),
        "a call argument of another kind is taken" },
    { ( if list.member(encoding, assert_statuses) then yes else no ),
        "encoding is not an assert's status" },
    { ( if list.member(engine_halted, assert_statuses) then no else yes ),
        "engine_halted is an assert's status" },
    { ( if list.member(state, assert_statuses) then no else yes ),
        "state is an assert's status" },
    { ( if list.member(state, seed_statuses) then yes else no ),
        "state is not a seed's status" },
    { ( if
            take_str([3, 0, 0x61, 0x62, 0x63, 5], Str, Rest),
            Str = [0x61, 0x62, 0x63],
            Rest = [5]
        then yes else no ),
        "take_str reads a str operand wrong" },
    { ( if take_str([3, 0, 0x61], _, _) then no else yes ),
        "take_str reads past the script" },
    { ( if le_uint64([1, 0, 0, 0, 0, 0, 0, 0]) = 1u64 then yes else no ),
        "le_uint64 reads the octets in the wrong order" },
    { ( if le_int64([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) = -1i64
        then yes else no ),
        "le_int64 reads -1 wrong" },
    { ( if le_int64([0, 0, 0, 0, 0, 0, 0, 0x80]) = int64.min_int64
        then yes else no ),
        "le_int64 reads the least int64 wrong" },
    { ( if float_of_bits(le_uint64([0, 0, 0, 0, 0, 0, 0xf0, 0x3f])) = 1.0
        then yes else no ),
        "float_of_bits reads 1.0's bits wrong" },
    { ( if float.is_nan(float_of_bits(0x7FF8000000000000u64))
        then yes else no ),
        "float_of_bits reads a NaN as a number" }
].

    % A NaN. (Not `nan`, which may be the standard library's.)
    %
:- func a_nan = float.

a_nan = float.infinity - float.infinity.

:- func good_args = list(arg).

good_args = [arg("b", av_bytes([])), arg("f", av_float(1.0)),
    arg("i", av_int(1i64)), arg("j", av_json("{}")),
    arg("s", av_string("x"))].

    % The good arguments, with the one of this name replaced.
    %
:- func with_arg(arg) = list(arg).

with_arg(New) = list.map(
    (func(Old) = ( if name_of(Old) = name_of(New) then New else Old )),
    good_args).

:- func stray_text = string.

stray_text = Text :-
    ( if octets_text([0x61, 0xff]) = yes(Text0) then
        Text = Text0
    else
        Text = ""
    ).

    % Ill-formed text one octet past the text limit.
    %
:- func long_ill_formed = list(int).

long_ill_formed = [0xff | list.duplicate(max_text_bytes, 0x20)].

%---------------------------------------------------------------------------%
% Files
%---------------------------------------------------------------------------%

:- pred read_bytes(string::in, maybe_error(bitmap, string)::out,
    io::di, io::uo) is det.

read_bytes(Path, Result, !IO) :-
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

:- func bitmap_bytes(bitmap) = list(int).

bitmap_bytes(BM) = list.map((func(I) = BM ^ bitmap.byte(I)),
    0 .. (bitmap.det_num_bytes(BM) - 1)).

:- func bytes_bitmap(list(int)) = bitmap.

bytes_bitmap(Bytes) =
    fill_bytes(Bytes, 0, bitmap.init(list.length(Bytes) * 8)).

:- func fill_bytes(list(int), int, bitmap) = bitmap.
:- mode fill_bytes(in, in, bitmap_di) = bitmap_uo is det.

fill_bytes([], _, BM) = BM.
fill_bytes([B | Bs], I, BM0) = fill_bytes(Bs, I + 1, BM0 ^ byte(I) := B).

%---------------------------------------------------------------------------%
:- end_module host_values_mercury.
%---------------------------------------------------------------------------%

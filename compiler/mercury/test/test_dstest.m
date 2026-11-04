% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_dstest -- `test` declarations, compiled to the T* / O* atoms.
%
% A loader skips the family ([RDSC.9.4]), so the atoms are read off the bytes
% with the runtime's frame and field readers and checked field by field
% against `proto/test_scenario.proto` and `proto/test_oracle.proto`.
%-----------------------------------------------------------------------------%

:- module test_dstest.
:- interface.

:- import_module io.

:- pred run(int::out, int::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.
:- import_module dsc.diag.
:- import_module dsc.driver.
:- import_module dsc.encode.
:- import_module dsc.token.

:- import_module ds.
:- import_module ds.atom.
:- import_module ds.wire.

:- import_module bitmap.
:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint32.
:- import_module uint64.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type tally
    --->    tally(
                t_pass :: int,
                t_fail :: int
            ).

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

run(Pass, Fail, !IO) :-
    cases(tally(0, 0), T, !IO),
    Pass = T ^ t_pass,
    Fail = T ^ t_fail.

%-----------------------------------------------------------------------------%
% Reading atoms back
%-----------------------------------------------------------------------------%

    % An atom and its fields, in wire order.
    %
:- type atom
    --->    atom(
                a_id     :: atom_id,
                a_fields :: list(pair(uint32, field_value))
            ).

:- func compile(string) = compile_result.

compile(Source) = Result :-
    compile_source(as_though("default"), Source, Result).

    % The test-family atoms of a compiled source, in emission order; `[]` when
    % the source did not compile.
    %
:- func test_atoms(string) = list(atom).

test_atoms(Source) = Atoms :-
    ( if compile(Source) = compiled(Bytes, _, _) then
        Atoms = list.filter(is_test_atom, all_atoms(Bytes))
    else
        Atoms = []
    ).

:- pred is_test_atom(atom::in) is semidet.

is_test_atom(A) :-
    list.member(A ^ a_id, [at_test_case, at_test_fact, at_test_cache_seed, at_test_response, at_test_reply,
        at_oracle_activated, at_oracle_emit, at_oracle_publish, at_oracle_call, at_oracle_cache_set, at_oracle_cache_delete,
        at_oracle_log, at_oracle_retract, at_oracle_working_memory]).

:- func all_atoms(list(uint8)) = list(atom).

all_atoms(Bytes) = list.reverse(walk(init_reader(from_bytes(Bytes)), [])).

:- func walk(reader, list(atom)) = list(atom).

walk(R0, Acc) = Atoms :-
    next_frame(FrameResult, R0, R1),
    (
        FrameResult = fr_ok(Frame),
        ( if Frame ^ fr_atom = known(Id) then
            Atoms = walk(R1, [atom(Id, fields(Frame ^ fr_body)) | Acc])
        else
            Atoms = walk(R1, Acc)
        )
    ;
        ( FrameResult = fr_eof
        ; FrameResult = fr_error(_, _)
        ),
        Atoms = Acc
    ).

:- func fields(reader) = list(pair(uint32, field_value)).

fields(R0) = Fs :-
    next_field(FieldResult, R0, R1),
    (
        FieldResult = field(Num, Value),
        Fs = [Num - Value | fields(R1)]
    ;
        ( FieldResult = fields_end
        ; FieldResult = field_error(_)
        ),
        Fs = []
    ).

    % Whether an ASCII name appears anywhere in an artefact's bytes. Compared
    % as bytes, never as a Mercury string: a `.dsc` carries 0x00 bytes, and
    % `string.from_char_list` throws on a NUL.
    %
:- pred bytes_contain(list(uint8)::in, string::in) is semidet.

bytes_contain(Bytes, Name) :-
    has_infix(list.map(uint8.to_int, Bytes),
        list.map(char.to_int, string.to_char_list(Name))).

:- pred has_infix(list(int)::in, list(int)::in) is semidet.

has_infix(Hay, Needle) :-
    ( if list.append(Needle, _, Hay) then
        true
    else
        Hay = [_ | Tail],
        has_infix(Tail, Needle)
    ).

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

    % Whether field `N` is present as a `fixed64` -- a `double`.
    %
:- pred has_fixed64(atom::in, uint32::in) is semidet.

has_fixed64(A, N) :-
    list.any_true(( pred(F::in) is semidet :- F = N - fv_fixed64(_) ),
        A ^ a_fields).

    % The varint at field `N`, if present.
    %
:- func varint(atom, uint32) = uint64 is semidet.

varint(A, N) = V :-
    % Bind, then match: a `_` inside an output argument is a mode error.
    list.find_first_match(( pred(F::in) is semidet :- F = N - fv_varint(_) ),
        A ^ a_fields, Found),
    Found = _ - fv_varint(V).

    % A varint field that proto3 omits at zero, read as 0 when absent.
    %
:- func varint0(atom, uint32) = uint64.

varint0(A, N) = ( if V = varint(A, N) then V else 0u64 ).

:- func str(atom, uint32) = string is semidet.

str(A, N) = S :-
    list.find_first_match(( pred(F::in) is semidet :- F = N - fv_bytes(_) ),
        A ^ a_fields, Found),
    Found = _ - fv_bytes(R),
    reader_string(R, S).

    % Every nested message at field `N`, as its own field list.
    %
:- func messages(atom, uint32) = list(atom).

messages(A, N) = Ms :-
    % The `pred` form, with its modes written out: a `func` lambda in
    % `filter_map`'s semidet position does not pass the mode check.
    list.filter_map(
        ( pred(F::in, M::out) is semidet :-
            F = N - fv_bytes(R),
            M = atom(A ^ a_id, fields(R))
        ),
        A ^ a_fields, Ms).

    % The field numbers present, in order.
    %
:- func numbers(atom) = list(uint32).

numbers(A) = list.map(pair.fst, A ^ a_fields).

:- func ids(list(atom)) = list(atom_id).

ids(As) = list.map(( func(A) = A ^ a_id ), As).

    % The `DS_VALIDATE_*` / `DS_*` names a rejected compile reported.
    %
:- func codes(string) = list(string).

codes(Source) = Codes :-
    ( if compile(Source) = compile_rejected(Ds) then
        Codes = list.map(( func(D) = code_name(D ^ dg_code) ), Ds)
    else
        Codes = []
    ).

:- func has_code(string, string) = bool.

has_code(Source, Code) =
    ( if list.member(Code, codes(Source)) then yes else no ).

%-----------------------------------------------------------------------------%
% Sources
%-----------------------------------------------------------------------------%

:- func program = string.

program =
    "schema TempReading scope logical:\n" ++
    "    zone: String key\n" ++
    "    celsius: Float mutable\n" ++
    "    n: Int mutable\n" ++
    "schema HeaterOn scope logical:\n" ++
    "    zone: String key\n" ++
    "schema Shutdown scope logical:\n" ++
    "    zone: String key\n" ++
    "\n" ++
    "rule cold_detected:\n" ++
    "    TempReading t where t.celsius < 5.0\n" ++
    "->\n" ++
    "    emit HeaterOn logical zone: \"cellar\"\n" ++
    "\n".

:- func with_test(string) = string.

with_test(Body) = program ++ "test \"cold\":\n" ++ Body.

    % `with_test`, with the `calendar` module imported both ways, so a
    % coordinate may be written `calendar.time(...)` or `time(...)`
    % ([LIMP.3.3.4]).
    %
:- func with_calendar_test(string) = string.

with_calendar_test(Body) =
    "import calendar\nfrom calendar import time\n\n" ++ with_test(Body).

    % [LTSL.3.7]: the coordinate `At` is refused with
    % DS_VALIDATE_TEST_BAD_TIMESTAMP.
    %
:- pred check_bad_timestamp(pair(string, string)::in, tally::in, tally::out,
    io::di, io::uo) is det.

check_bad_timestamp(What - At, !T, !IO) :-
    check("[LTSL.3.7] " ++ What ++ " is a bad timestamp",
        has_code(with_calendar_test("    inputs:\n" ++
            "        at " ++ At ++ ":\n" ++
            "            TempReading zone: \"x\" celsius: 1.0 n: 1\n"
            ++ "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_BAD_TIMESTAMP"), !T, !IO).

    % A service answering with `HeaterAck`, and one answering nothing, for the
    % stub cases ([LTSL.7.3], [LTSL.7.5]).
    %
:- func heater_service = string.

heater_service =
    "schema HeaterAck scope ttl 1_min:\n" ++
    "    corr: String\n" ++
    "\n" ++
    "service heater.on:\n" ++
    "    response HeaterAck\n" ++
    "\n" ++
    "service heater.off:\n" ++
    "    no response\n" ++
    "\n".

%-----------------------------------------------------------------------------%
% Cases
%-----------------------------------------------------------------------------%

:- pred cases(tally::in, tally::out, io::di, io::uo) is det.

cases(!T, !IO) :-
    Basic = with_test(
        "    inputs:\n" ++
        "        at 0_s:\n" ++
        "            TempReading zone: \"cellar\" celsius: 2.0 n: 0\n" ++
        "        at 5_min:\n" ++
        "            TempReading zone: \"attic\" celsius: 9.5 n: 3\n" ++
        "    produces:\n" ++
        "        activated cold_detected\n" ++
        "        emitted HeaterOn zone: \"cellar\"\n" ++
        "        never emitted Shutdown\n"),
    As = test_atoms(Basic),

    % A rule that cannot lower refuses the compile.
    check("[RLOW.17.1] a test compiles, with no declaration left unlowered",
        ( if compile(Basic) = compiled(_, _, _) then yes else no ), !T, !IO),
    check("[RDSC.8.1] the group is TestCase, the facts, then the oracles",
        ( if ids(As) = [at_test_case, at_test_fact, at_test_fact, at_oracle_activated, at_oracle_emit, at_oracle_emit]
          then yes else no ), !T, !IO),

    ( if As = [Case, Fact1, Fact2, Act, Emit, Never] then
        check("[RLOW.17.1] TestCase: test_id 1, the name, relative time",
            ( if varint(Case, 1u32) = 1u64, str(Case, 2u32) = "cold",
                 varint0(Case, 5u32) = 0u64
              then yes else no ), !T, !IO),
        check("TestCase carries the file module's module_id",
            ( if varint(Case, 4u32) > 0u64 then yes else no ), !T, !IO),
        check("[LTSL.3.1] the first input is at 0, the second at 5 minutes",
            ( if varint0(Fact1, 3u32) = 0u64,
                 varint(Fact2, 3u32) = 300000000000u64
              then yes else no ), !T, !IO),
        check("[LTSL.3.3] source_order counts across blocks",
            ( if varint0(Fact1, 6u32) = 0u64, varint(Fact2, 6u32) = 1u64
              then yes else no ), !T, !IO),
        check("[RLOW.17.3] TestFact names its schema",
            ( if str(Fact1, 4u32) = "TempReading" then yes else no ), !T, !IO),
        ( if messages(Fact1, 5u32) = [Zone, Celsius, Count] then
            check("[LTSL.4.1] a String literal is s_val (4)",
                ( if str(Zone, 1u32) = "zone", str(Zone, 4u32) = "cellar"
                  then yes else no ), !T, !IO),
            check("[LTSL.4.1] a Float literal is f_val (3), a fixed64",
                ( if str(Celsius, 1u32) = "celsius",
                     has_fixed64(Celsius, 3u32)
                  then yes else no ), !T, !IO),
            check("an Int 0 is WRITTEN: a oneof member at its default is "
                    ++ "still the member",
                ( if numbers(Count) = [1u32, 2u32], varint(Count, 2u32) = 0u64
                  then yes else no ), !T, !IO)
        else
            check("TestFact carries three slot literals", no, !T, !IO)
        ),
        check("[LTSL.8.2] OracleActivated names the rule, polarity POS (1)",
            ( if str(Act, 3u32) = "cold_detected", varint(Act, 2u32) = 1u64
              then yes else no ), !T, !IO),
        check("[LTSL.8.4] OracleEmit carries the schema and a subset match",
            ( if str(Emit, 3u32) = "HeaterOn",
                 list.length(messages(Emit, 4u32)) = 1,
                 varint0(Emit, 5u32) = 0u64
              then yes else no ), !T, !IO),
        check("[LTSL.8.3] `never` is polarity NEVER (2)",
            ( if str(Never, 3u32) = "Shutdown", varint(Never, 2u32) = 2u64
              then yes else no ), !T, !IO)
    else
        check("the basic test lowers to six atoms", no, !T, !IO)
    ),

    % [LTSL.3.2] / [LTSL.3.7]: absolute coordinates are `calendar.time` calls,
    % folded at compile time ([LTIM.14.3]), qualified or bare.
    % 2026-06-18T14:00:00Z is 1781791200 seconds after the epoch.
    Abs = test_atoms(with_calendar_test(
        "    inputs:\n" ++
        "        at calendar.time(2026, 6, 18, 14, 0, 0):\n" ++
        "            TempReading zone: \"a\" celsius: 1.0 n: 1\n" ++
        "        at time(2026, 6, 18, 14, 0, 0, 500000000):\n" ++
        "            TempReading zone: \"b\" celsius: 1.0 n: 1\n" ++
        "    produces:\n" ++
        "        activated cold_detected\n")),
    ( if Abs = [AbsCase, AbsFact1, AbsFact2 | _] then
        check("[LTSL.3.2] absolute mode is recorded on the case",
            ( if varint(AbsCase, 5u32) = 1u64 then yes else no ), !T, !IO),
        check("[LTSL.3.7] calendar.time/6 folds to the exact epoch nanosecond",
            ( if varint(AbsFact1, 3u32) = 1781791200000000000u64
              then yes else no ), !T, !IO),
        check("[LTSL.3.7] a bare time/7 folds its nanoseconds exactly",
            ( if varint(AbsFact2, 3u32) = 1781791200500000000u64
              then yes else no ), !T, !IO)
    else
        check("an absolute test compiles", no, !T, !IO)
    ),

    % [LTSL.5.2]: a cache seed after every TestFact, carrying the literal.
    Seeded = test_atoms(with_test(
        "    initial:\n" ++
        "        cache \"threshold\": 5.0\n" ++
        "        TempReading zone: \"x\" celsius: 1.0 n: 1\n" ++
        "    inputs:\n" ++
        "        at 1_s:\n" ++
        "            TempReading zone: \"y\" celsius: 1.0 n: 1\n" ++
        "    produces:\n" ++
        "        cached \"threshold\"\n")),
    check("[RDSC.8.1] every TestFact precedes the TestCacheSeed",
        ( if ids(Seeded) = [at_test_case, at_test_fact, at_test_fact, at_test_cache_seed, at_oracle_cache_set]
          then yes else no ), !T, !IO),
    ( if Seeded = [_, Init, _, Seed, _] then
        check("[LTSL.5.3] an `initial` fact is marked is_initial",
            ( if varint(Init, 2u32) = 1u64 then yes else no ), !T, !IO),
        check("[LTSL.5.2] TestCacheSeed carries the key and the Float literal",
            ( if str(Seed, 2u32) = "threshold",
                 messages(Seed, 3u32) = [V],
                 has_fixed64(V, 3u32)
              then yes else no ), !T, !IO)
    else
        true
    ),

    % [LTSL.7]: a stub, keyed by correlation, with a reply and a delay. The
    % reply is a fact of the service's response schema ([LTSL.7.3]).
    Stubbed = test_atoms(heater_service ++ with_test(
        "    inputs:\n" ++
        "        at 0_s:\n" ++
        "            TempReading zone: \"c\" celsius: 1.0 n: 1\n" ++
        "    responses:\n" ++
        "        for call heater.on as \"h1\" after 2_s:\n" ++
        "            HeaterAck corr: \"h1\"\n" ++
        "    produces:\n" ++
        "        called heater.on as \"h1\"\n")),
    check("[RDSC.8.1] a stub is TestResponse then its TestReply, before the oracles",
        ( if ids(Stubbed) = [at_test_case, at_test_fact, at_test_response, at_test_reply, at_oracle_call]
          then yes else no ), !T, !IO),
    ( if Stubbed = [_, _, Stub, Reply, Call] then
        check("[LTSL.7.2] TestResponse: service, correlation, stub_id 1",
            ( if varint(Stub, 1u32) = 1u64, str(Stub, 3u32) = "heater.on",
                 str(Stub, 4u32) = "h1"
              then yes else no ), !T, !IO),
        check("[LTSL.7.4] `after 2_s` is after_ns",
            ( if varint(Stub, 6u32) = 2000000000u64 then yes else no ),
            !T, !IO),
        check("[LTSL.7.3] TestReply joins its stub and names the response schema",
            ( if varint(Reply, 1u32) = 1u64,
                 str(Reply, 2u32) = "HeaterAck"
              then yes else no ), !T, !IO),
        check("[LTSL.8.2] OracleCall carries the correlation it was given",
            ( if str(Call, 3u32) = "heater.on", varint(Call, 4u32) = 1u64,
                 str(Call, 5u32) = "h1"
              then yes else no ), !T, !IO)
    else
        true
    ),

    % [LTSL.7.3]: a reply of another schema is refused; `CallError` is not.
    StubReply = ( func(Reply) = heater_service ++ with_test(
        "    inputs:\n" ++
        "        at 0_s:\n" ++
        "            TempReading zone: \"c\" celsius: 1.0 n: 1\n" ++
        "    responses:\n" ++
        "        for call heater.on as \"h1\":\n" ++
        "            " ++ Reply ++ "\n" ++
        "    produces:\n" ++
        "        called heater.on as \"h1\"\n") ),
    check("[LTSL.7.3] a reply of another schema is refused",
        has_code(StubReply("HeaterOn zone: \"c\""),
            "DS_VALIDATE_TEST_STUB_REPLY_TYPE"), !T, !IO),
    % No `ts:`: the engine fills it ([LFAC.9.3]).
    ErrReply = StubReply("CallError corr: \"h1\" code: \"x\" "
        ++ "message: \"m\""),
    ( if compile(ErrReply) = compiled(_, _, _) then
        ErrOk = yes
    else
        ErrOk = no,
        io.write_line(codes(ErrReply), !IO)
    ),
    check("[LTSL.7.3] a `CallError` reply is admitted", ErrOk, !T, !IO),
    % [LTSL.7.5]: a `no response` service's stub replies nothing.
    check("[LTSL.7.5] a reply to a `no response` service is refused",
        has_code(heater_service ++ with_test(
            "    responses:\n" ++
            "        for call heater.off as \"h2\":\n" ++
            "            HeaterAck corr: \"h2\"\n" ++
            "    produces:\n" ++
            "        called heater.off as \"h2\"\n"),
            "DS_VALIDATE_TEST_STUB_NO_RESPONSE_MISMATCH"), !T, !IO),
    % [LTSL.8.2]: `recorded` is not a head.
    check("[LTSL.8.2] `recorded` is refused",
        has_code(with_test(
            "    produces:\n" ++
            "        recorded heater\n"),
            "DS_VALIDATE_TEST_RECORDED_RETIRED"), !T, !IO),

    % [RTIM.14.11]: a `where` is a rule, and the artefact carries it.
    WhereSrc = with_test(
        "    inputs:\n" ++
        "        at 0_s:\n" ++
        "            TempReading zone: \"c\" celsius: 1.0 n: 1\n" ++
        "    produces:\n" ++
        "        activated cold_detected\n" ++
        "        emitted HeaterOn h where h.zone == \"cellar\"\n"),
    ( if compile(WhereSrc) = compiled(WhereBytes, _, _) then
        check("the oracle rule is named $dstest_oracle_1_1",
            ( if bytes_contain(WhereBytes, "$dstest_oracle_1_1")
              then yes else no ), !T, !IO),
        WhereAtoms = list.filter(is_test_atom, all_atoms(WhereBytes)),
        check("[LTSL.8.4] the OracleEmit carries has_where",
            ( if list.find_first_match(
                    ( pred(A::in) is semidet :- A ^ a_id = at_oracle_emit ),
                    WhereAtoms, E),
                 varint(E, 5u32) = 1u64
              then yes else no ), !T, !IO)
    else
        check("[RTIM.14.11] a `where` assertion compiles, its oracle rule "
            ++ "lowered", no, !T, !IO)
    ),

    % [RLOW.17.3] and [LTSL] refusals, by code.
    check("[RLOW.17.3] activated of an unknown rule",
        has_code(with_test("    produces:\n        activated nope\n"),
            "DS_VALIDATE_TEST_UNKNOWN_RULE"), !T, !IO),
    check("[RLOW.17.3] an input of an unknown schema",
        has_code(with_test("    inputs:\n        at 0_s:\n" ++
            "            Nope zone: \"x\"\n" ++
            "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_UNKNOWN_SCHEMA"), !T, !IO),
    check("[RLOW.17.3] a slot the schema lacks",
        has_code(with_test("    inputs:\n        at 0_s:\n" ++
            "            TempReading zone: \"x\" nope: 1\n" ++
            "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_UNKNOWN_SLOT"), !T, !IO),
    check("[LTSL.4.1] a non-literal value",
        has_code(with_test("    inputs:\n        at 0_s:\n" ++
            "            TempReading zone: \"x\" celsius: 1.0 + 2.0 n: 1\n"
            ++ "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_NON_LITERAL"), !T, !IO),
    % [LTSL.3.7]: every coordinate that is not a duration literal or a
    % folding `calendar.time` call is DS_VALIDATE_TEST_BAD_TIMESTAMP.
    list.foldl2(check_bad_timestamp, [
            "a quoted stamp" - "\"2026-06-18T14:00:00Z\"",
            "a fold that raises DOMAIN" - "calendar.time(2026, 2, 30)",
            "a fold that raises NOT_REPRESENTABLE" - "calendar.time(2262, 4, 12)",
            "an instant before 1970" - "calendar.time(1969, 12, 31, 23, 59, 59)",
            "a `calendar.date` call" - "calendar.date(2026, 6, 18)"
        ], !T, !IO),
    check("[LTSL.3.7] the epoch itself is a timestamp",
        ( if
            has_code(with_calendar_test("    inputs:\n" ++
                "        at calendar.time(1970, 1, 1):\n" ++
                "            TempReading zone: \"x\" celsius: 1.0 n: 1\n" ++
                "    produces:\n        activated cold_detected\n"),
                "DS_VALIDATE_TEST_BAD_TIMESTAMP") = no
          then yes else no ), !T, !IO),
    check("[LTSL.3.2] relative and absolute mixed",
        has_code(with_calendar_test("    inputs:\n" ++
            "        at 0_s:\n" ++
            "            TempReading zone: \"x\" celsius: 1.0 n: 1\n" ++
            "        at calendar.time(2026, 6, 18, 14, 0, 0):\n" ++
            "            TempReading zone: \"y\" celsius: 1.0 n: 1\n" ++
            "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_MIXED_TIME_MODE"), !T, !IO),
    check("[LTSL.7.2] a stub keyed by neither correlation nor arguments",
        has_code(with_test("    responses:\n" ++
            "        for call heater.on:\n" ++
            "            no response\n" ++
            "    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_STUB_UNKEYED"), !T, !IO),

    % [LTSL.2.3]'s three refusals, each with its own code.
    Input = "    inputs:\n        at 0_s:\n" ++
        "            TempReading zone: \"x\" celsius: 1.0 n: 1\n",
    check("[LTSL.2.3] a test with no produces",
        has_code(with_test(Input), "DS_VALIDATE_TEST_NO_PRODUCES"), !T, !IO),
    check("[LTSL.2.3] a repeated section keyword is refused, not merged",
        has_code(with_test(Input ++
            "    produces:\n        activated cold_detected\n" ++
            "    produces:\n        never emitted Shutdown\n"),
            "DS_VALIDATE_TEST_DUPLICATE_SECTION"), !T, !IO),
    check("[LTSL.2.3] a test with neither inputs nor until",
        has_code(with_test("    produces:\n        activated cold_detected\n"),
            "DS_VALIDATE_TEST_NO_INPUTS_OR_UNTIL"), !T, !IO),
    check("[LTSL.2.3] ... and `until` alone satisfies it",
        ( if has_code(with_test("    until 5_s\n" ++
                "    produces:\n        never emitted Shutdown\n"),
                "DS_VALIDATE_TEST_NO_INPUTS_OR_UNTIL") = no
          then yes else no ), !T, !IO),

    % [RTIM.14.13]: the oracle rules are `$`-named ([LLEX.10.6.1]), so no
    % author name is reserved. The rule reads its binding, so only the name
    % could refuse it.
    check("[RTIM.14.13] an author rule named `_dstest_oracle_9_9` compiles",
        ( if compile(program ++
                "rule _dstest_oracle_9_9:\n" ++
                "    TempReading t where t.celsius < 0.0\n->\n" ++
                "    emit Shutdown logical zone: t.zone\n") = compiled(_, _, _)
          then yes else no ), !T, !IO),

    % [RTIM.14.13]: `<t>` counts the file's tests from 1, `<i>` a test's
    % assertions from 0 -- `emitted ... where` makes a rule, `activated` makes
    % none but still takes an index.
    TwoTests = program ++
        "test \"one\":\n" ++ Input ++
        "    produces:\n" ++
        "        emitted HeaterOn h where h.zone == \"cellar\"\n" ++
        "test \"two\":\n" ++ Input ++
        "    produces:\n" ++
        "        activated cold_detected\n" ++
        "        emitted HeaterOn h where h.zone == \"attic\"\n",
    ( if compile(TwoTests) = compiled(TwoBytes, _, _) then
        check("[RTIM.14.13] test 1's first assertion is $dstest_oracle_1_0",
            ( if bytes_contain(TwoBytes, "$dstest_oracle_1_0")
              then yes else no ), !T, !IO),
        check("[RTIM.14.13] test 2's second assertion is $dstest_oracle_2_1",
            ( if bytes_contain(TwoBytes, "$dstest_oracle_2_1")
              then yes else no ), !T, !IO),
        check("[RTIM.14.13] an `activated` assertion makes no rule",
            ( if bytes_contain(TwoBytes, "$dstest_oracle_2_0")
              then no else yes ), !T, !IO)
    else
        check("[RTIM.14.13] a file with two tests compiles", no, !T, !IO)
    ).

%-----------------------------------------------------------------------------%
:- end_module test_dstest.
%-----------------------------------------------------------------------------%

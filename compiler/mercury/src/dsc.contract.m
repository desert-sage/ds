% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.contract -- a `.dsrt` realtime contract: read, checked, hashed.
%
% The contract value and its hash are the runtime's (`ds.contract`), so the
% compiler and the loader make one computation.
%
% Reads a subset of YAML: [RTCT.3.2]'s block layout. A key it cannot read counts
% as absent.
%-----------------------------------------------------------------------------%

:- module dsc.contract.
:- interface.

:- import_module ds.
:- import_module ds.contract.

:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.rete.

:- import_module list.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    %@helper
:- type contract_result
    --->    contract_ok(contract)
    ;       contract_errors(list(diagnostic)).

    % Departs from [RTCT.3.3] in three places: the cache caps are optional and
    % may be zero; a malformed value reports
    % `DS_VALIDATE_COMPILE_CONTRACT_INCOMPLETE`, not `DS_ERR_CONTRACT_INVALID`;
    % and series coverage is not checked.
    %
    %@spec [RTCT.3.1]
    %@spec [RTCT.3.2]
    %@spec [RTCT.3.3]
    %@spec [RTCT.3.4]
    %@spec [RTCT.4.5]
    %@spec [RTCT.6.7.7]
:- pred rtct_3_1_parse(string::in, contract_result::out) is det.

    %@spec [RTCT.4.4]
:- pred rtct_4_4_cover(rete_network::in, contract::in, list(diagnostic)::out)
    is det.

    %@helper
:- func rt_config_sha256(contract) = list(uint8).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.id.
:- import_module ds.network.
:- import_module ds.sha256.

:- import_module dsc.token.

:- import_module ds.
:- import_module ds.i64.
:- import_module assoc_list.
:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module int64.
:- import_module pair.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%
% The YAML subset
%-----------------------------------------------------------------------------%

    %@helper
:- type yline
    --->    yline(
                yl_no     :: int,
                yl_indent :: int,
                yl_text   :: string
            ).

    %@helper
:- type yentry
    --->    y_scalar(int, string)
    ;       y_list(int, list(assoc_list(string, pair(int, string)))).

    %@helper
:- func ylines(string) = list(yline).

ylines(Text) =
    list.filter_map(yline_of, numbered(string.split_at_char('\n', Text), 1)).

    %@helper
:- func numbered(list(string), int) = assoc_list(int, string).

numbered([], _) = [].
numbered([L | Ls], N) = [N - L | numbered(Ls, N + 1)].

    %@helper
:- func yline_of(pair(int, string)) = yline is semidet.

yline_of(N - Raw) = yline(N, Indent, Content) :-
    Kept = string.from_char_list(before_comment(string.to_char_list(Raw), yes)),
    Content = string.strip(Kept),
    Content \= "",
    Indent = leading_spaces(string.to_char_list(Kept), 0).

    % A `#` at the start of the line or after whitespace begins a comment.
    %
    %@helper
:- func before_comment(list(char), bool) = list(char).

before_comment([], _) = [].
before_comment([C | Cs], AfterSpace) =
    ( if C = ('#'), AfterSpace = yes then
        []
    else
        [C | before_comment(Cs, ( if char.is_whitespace(C) then yes else no ))]
    ).

    %@helper
:- func leading_spaces(list(char), int) = int.

leading_spaces([], N) = N.
leading_spaces([C | Cs], N) =
    ( if C = (' ') then leading_spaces(Cs, N + 1) else N ).

    %@helper
:- pred contract_block(list(yline)::in, list(yline)::out) is semidet.

contract_block([L | Ls], Block) :-
    ( if L ^ yl_indent = 0, L ^ yl_text = "contract:" then
        list.take_while(indented, Ls, Block, _)
    else
        contract_block(Ls, Block)
    ).

    %@helper
:- pred indented(yline::in) is semidet.

indented(L) :-
    L ^ yl_indent > 0.

    %@helper
:- pred key_value(string::in, string::out, string::out) is semidet.

key_value(Text, Key, Value) :-
    string.sub_string_search(Text, ":", Ix),
    Key = string.strip(string.left(Text, Ix)),
    Key \= "",
    Value = string.strip(string.right(Text, string.length(Text) - Ix - 1)).

    %@helper
:- func unquote(string) = string.

unquote(S) = Out :-
    ( if
        string.length(S) >= 2,
        First = string.left(S, 1),
        ( First = "\"" ; First = "'" ),
        string.right(S, 1) = First
    then
        Out = string.between(S, 1, string.length(S) - 1)
    else
        Out = S
    ).

    %@helper
:- pred entries(list(yline)::in, assoc_list(string, yentry)::in,
                assoc_list(string, yentry)::out) is det.

entries([], !Acc).
entries([L | Ls], !Acc) :-
    ( if key_value(L ^ yl_text, Key, Value) then
        ( if Value = "" then
            list.take_while(item_line(L ^ yl_indent), Ls, ItemLines, Rest),
            !:Acc = [Key - y_list(L ^ yl_no, items(ItemLines)) | !.Acc],
            entries(Rest, !Acc)
        else if Value = "[]" then
            !:Acc = [Key - y_list(L ^ yl_no, []) | !.Acc],
            entries(Ls, !Acc)
        else
            !:Acc = [Key - y_scalar(L ^ yl_no, Value) | !.Acc],
            entries(Ls, !Acc)
        )
    else
        entries(Ls, !Acc)
    ).

    % A line belonging to a block sequence under a key at `KeyIndent`: deeper,
    % or a `-` item at the same indent, which YAML allows.
    %
    %@helper
:- pred item_line(int::in, yline::in) is semidet.

item_line(KeyIndent, L) :-
    ( L ^ yl_indent > KeyIndent
    ; L ^ yl_indent = KeyIndent, string.prefix(L ^ yl_text, "-")
    ).

    %@helper
:- func items(list(yline)) = list(assoc_list(string, pair(int, string))).

items([]) = [].
items([L | Ls]) = Items :-
    ( if string.remove_prefix("-", L ^ yl_text, After) then
        list.take_while(continues(L ^ yl_indent), Ls, More, Rest),
        ( if key_value(string.strip(After), K, V) then
            First = [K - (L ^ yl_no - V)]
        else
            First = []
        ),
        Items = [First ++ list.filter_map(item_kv, More) | items(Rest)]
    else
        Items = items(Ls)
    ).

    %@helper
:- pred continues(int::in, yline::in) is semidet.

continues(DashIndent, L) :-
    L ^ yl_indent > DashIndent,
    not string.prefix(L ^ yl_text, "-").

    %@helper
:- func item_kv(yline) = pair(string, pair(int, string)) is semidet.

item_kv(L) = K - (L ^ yl_no - V) :-
    key_value(L ^ yl_text, K, V).

%-----------------------------------------------------------------------------%
% The contract
%-----------------------------------------------------------------------------%

rtct_3_1_parse(Text, Result) :-
    ( if contract_block(ylines(Text), Block) then
        entries(Block, [], RevEntries),
        Entries = list.reverse(RevEntries),
        Max32 = 0x7FFFFFFFi64,
        required(Entries, "wm_max", Max32, Wm, [], E1),
        required(Entries, "agenda_cap", Max32, Agenda, E1, E2),
        required(Entries, "max_fires_per_pump", Max32, Fires, E2, E3),
        required(Entries, "token_pool_cap", Max32, Tokens, E3, E4),
        required(Entries, "intern_cap", Max32, Intern, E4, E5),
        required(Entries, "intern_bytes_cap", Max32, InternBytes, E5, E6),
        required(Entries, "pump_wcet_ns", Max32, Wcet, E6, E7),
        optional(Entries, "cache_cap", Max32, CacheCap, E7, E8),
        optional(Entries, "cache_bytes_cap", int64.max_int64, CacheBytes,
            E8, E9),
        node_caps(Entries, Nodes, E9, E10),
        series_caps(Entries, Series, E10, Errors),
        (
            Errors = [],
            Result = contract_ok(contract(u32(Wm), u32(Agenda), u32(Fires),
                u32(Tokens), u32(Intern), u32(InternBytes), u64(Wcet),
                list.sort(Nodes), list.sort(Series), [], u32(CacheCap),
                u64(CacheBytes), 0u32, 0u32, [], []))
        ;
            Errors = [_ | _],
            Result = contract_errors(list.reverse(Errors))
        )
    else
        Result = contract_errors([incomplete(1,
            "the `.dsrt` has no top-level `contract:` mapping ([RTCT.3.1])")])
    ).

    % The value is at most 0x7FFFFFFF here, so the cast to `int` is exact.
    %
    %@helper
:- func u32(int64) = uint32.

u32(I) = uint32.det_from_int(int64.cast_to_int(I)).

    %@helper
:- func u64(int64) = uint64.

u64(I) = uint64.cast_from_int64(I).

    %@helper
:- func incomplete(int, string) = diagnostic.

incomplete(Line, Message) =
    error_at(dv_compile_contract_incomplete, pos(Line, 1), Message).

    %@helper
:- pred required(assoc_list(string, yentry)::in, string::in, int64::in,
                 int64::out, list(diagnostic)::in, list(diagnostic)::out) is det.

required(Entries, Name, Max, Value, !Errors) :-
    ( if assoc_list.search(Entries, Name, y_scalar(Line, Text)) then
        in_range(Name, Line, Text, 1i64, Max, Value, !Errors)
    else
        Value = 0i64,
        !:Errors = [incomplete(1, "`contract." ++ Name ++ "` is required "
            ++ "([RTCT.3.3])") | !.Errors]
    ).

    % Absent is zero.
    %
    %@helper
:- pred optional(assoc_list(string, yentry)::in, string::in, int64::in,
                 int64::out, list(diagnostic)::in, list(diagnostic)::out) is det.

optional(Entries, Name, Max, Value, !Errors) :-
    ( if assoc_list.search(Entries, Name, y_scalar(Line, Text)) then
        in_range(Name, Line, Text, 0i64, Max, Value, !Errors)
    else
        Value = 0i64
    ).

    %@helper
:- pred in_range(string::in, int::in, string::in, int64::in, int64::in,
                 int64::out,
                 list(diagnostic)::in, list(diagnostic)::out) is det.

in_range(Name, Line, Text, Min, Max, Value, !Errors) :-
    ( if i64.from_decimal(Text, V), V >= Min, V =< Max then
        Value = V
    else
        Value = 0i64,
        !:Errors = [incomplete(Line, "`contract." ++ Name ++ "` must be an "
            ++ "integer in " ++ string.int64_to_string(Min) ++ ".."
            ++ string.int64_to_string(Max) ++ ", not `" ++ Text
            ++ "` ([RTCT.3.3])") | !.Errors]
    ).

    %@helper
:- pred node_caps(assoc_list(string, yentry)::in, list(node_cap)::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

node_caps(Entries, Nodes, !Errors) :-
    ( if assoc_list.search(Entries, "nodes", y_list(_, Items)) then
        list.foldl2(node_item, Items, [], RevNodes, !Errors),
        Nodes = list.reverse(RevNodes)
    else
        Nodes = []
    ).

    %@helper
:- pred node_item(assoc_list(string, pair(int, string))::in,
                  list(node_cap)::in, list(node_cap)::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

node_item(Item, !Nodes, !Errors) :-
    Max = 0x7FFFFFFFi64,
    ( if
        assoc_list.search(Item, "node_id", IdLine - IdText),
        assoc_list.search(Item, "kind", KindLine - KindText),
        % A quoted number is not a number, so only `kind` is unquoted.
        Kind = unquote(KindText),
        assoc_list.search(Item, "capacity", CapLine - CapText)
    then
        in_range("nodes[].node_id", IdLine, IdText, 1i64, Max, Id, !Errors),
        in_range("nodes[].capacity", CapLine, CapText, 1i64, Max, Cap,
            !Errors),
        ( if ( Kind = "alpha" ; Kind = "beta" ; Kind = "term" ) then
            true
        else
            !:Errors = [incomplete(KindLine, "`contract.nodes[].kind` must be "
                ++ "alpha, beta or term, not `" ++ Kind ++ "` ([RTCT.3.3])")
                | !.Errors]
        ),
        ( if list.find_first_match((pred(N::in) is semidet :-
                N ^ nc_id = u32(Id)), !.Nodes, _), Id > 0i64
        then
            !:Errors = [incomplete(IdLine, "duplicate `node_id` "
                ++ string.int64_to_string(Id) ++ " ([RTCT.3.3])") | !.Errors]
        else
            !:Nodes = [node_cap(u32(Id), Kind, u32(Cap)) | !.Nodes]
        )
    else
        !:Errors = [incomplete(1, "a `contract.nodes[]` entry lacks one of "
            ++ "`node_id`, `kind`, `capacity` ([RTCT.3.3])") | !.Errors]
    ).

    %@helper
:- pred series_caps(assoc_list(string, yentry)::in, list(series_cap)::out,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

series_caps(Entries, Series, !Errors) :-
    ( if assoc_list.search(Entries, "series", y_list(_, Items)) then
        list.foldl2(series_item, Items, [], RevSeries, !Errors),
        Series = list.reverse(RevSeries)
    else
        Series = []
    ).

    %@helper
:- pred series_item(assoc_list(string, pair(int, string))::in,
                    list(series_cap)::in, list(series_cap)::out,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

series_item(Item, !Series, !Errors) :-
    Max = 0x7FFFFFFFi64,
    ( if
        assoc_list.search(Item, "series_id", IdLine - IdText),
        assoc_list.search(Item, "capacity", CapLine - CapText)
    then
        in_range("series[].series_id", IdLine, IdText, 0i64, Max, Id,
            !Errors),
        in_range("series[].capacity", CapLine, CapText, 1i64, Max, Cap,
            !Errors),
        ( if list.find_first_match((pred(S::in) is semidet :-
                S ^ sc_id = u32(Id)), !.Series, _)
        then
            !:Errors = [incomplete(IdLine, "duplicate `series_id` "
                ++ string.int64_to_string(Id) ++ " ([RTCT.3.3])") | !.Errors]
        else
            !:Series = [series_cap(u32(Id), u32(Cap)) | !.Series]
        )
    else
        !:Errors = [incomplete(1, "a `contract.series[]` entry lacks "
            ++ "`series_id` or `capacity` ([RTCT.3.3])") | !.Errors]
    ).

%-----------------------------------------------------------------------------%
% Against the network, and the hash
%-----------------------------------------------------------------------------%

rtct_4_4_cover(Net, C, Errors) :-
    Expected = list.sort(
        list.map(alpha_kind, Net ^ rn_alphas) ++
        list.map(beta_kind, Net ^ rn_betas) ++
        list.map(term_kind, Net ^ rn_terms)),
    Declared = list.map(declared_kind, C ^ c_nodes),
    Missing = list.filter(absent_from(Declared), Expected),
    Unknown = list.filter(absent_from(Expected), Declared),
    WrongKind = list.filter(kind_differs(Expected), Declared),
    Errors =
        ( if Missing = [] then [] else
            [incomplete(1, "the contract has no `contract.nodes[]` entry for "
                ++ "node_id " ++ ids(Missing) ++ " ([RTCT.3.3], [RTCT.4.4])")] )
        ++ ( if Unknown = [] then [] else
            [incomplete(1, "the contract names node_id " ++ ids(Unknown)
                ++ ", which the network does not have ([RTCT.4.4])")] )
        ++ ( if WrongKind = [] then [] else
            [incomplete(1, "the contract gives node_id " ++ ids(WrongKind)
                ++ " a kind the network does not ([RTCT.4.4])")] ).

    %@helper
:- func declared_kind(node_cap) = pair(int, string).

declared_kind(N) = uint32.cast_to_int(N ^ nc_id) - N ^ nc_kind.

    %@helper
:- pred absent_from(assoc_list(int, string)::in, pair(int, string)::in)
    is semidet.

absent_from(Others, Id - _) :-
    not assoc_list.search(Others, Id, _).

    %@helper
:- pred kind_differs(assoc_list(int, string)::in, pair(int, string)::in)
    is semidet.

kind_differs(Expected, Id - Kind) :-
    assoc_list.search(Expected, Id, Actual),
    Actual \= Kind.

    %@helper
:- func ids(assoc_list(int, string)) = string.

ids(Pairs) = string.join_list(", ", list.map(id_text, Pairs)).

    %@helper
:- func id_text(pair(int, string)) = string.

id_text(Id - _) = string.from_int(Id).

    %@helper
:- func alpha_kind(raw_alpha) = pair(int, string).

alpha_kind(raw_alpha(Id, _, _)) = uint32.cast_to_int(node_id_value(Id)) - "alpha".

    %@helper
:- func beta_kind(raw_beta) = pair(int, string).

beta_kind(raw_beta(Id, _, _, _, _)) =
    uint32.cast_to_int(node_id_value(Id)) - "beta".

    %@helper
:- func term_kind(raw_terminal) = pair(int, string).

term_kind(raw_terminal(Id, _, _, _, _, _, _)) =
    uint32.cast_to_int(node_id_value(Id)) - "term".

rt_config_sha256(C) =
    sha256(list.map(char_byte,
        string.to_char_list(canonical(C, canonical_placement)))).

    %@helper
:- func char_byte(char) = uint8.

char_byte(Ch) = uint8.det_from_int(char.to_int(Ch)).

%-----------------------------------------------------------------------------%
:- end_module dsc.contract.
%-----------------------------------------------------------------------------%

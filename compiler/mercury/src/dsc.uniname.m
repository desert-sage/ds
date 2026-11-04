% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.uniname -- identifier legality, mixed-script, and NFC, over the pinned
% Unicode 16.0 tables.
%
% The data is `dsc.unicode`, generated. Nothing here calls a host classifier such
% as `char.is_alpha`: those follow the Unicode `mmc` was built with ([LNAM.2.2.5]).
%-----------------------------------------------------------------------------%

:- module dsc.uniname.
:- interface.

:- import_module char.
:- import_module list.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@spec [LNAM.2.2.1]
    %@spec [LLEX.10.8.1]
:- pred lnam_2_2_1_id_start(char::in) is semidet.

    %@spec [LNAM.2.2.1]
    %@spec [LNAM.2.2.2]
    %@spec [LNAM.2.6.2]
:- pred lnam_2_2_1_id_continue(char::in) is semidet.

    % The resolved script-extension set of a codepoint, short codes.
    %
    %@helper
:- func script_set(char) = list(string).

    %@spec [LNAM.2.4.1]
    %@spec [LLEX.10.8.2]
    %@spec [LNAM.2.3.1]
:- func lnam_2_4_1_nfc(string) = string.

    % UAX #39 Highly Restrictive. Fails for a genuinely mixed-script name.
    %
    %@spec [LNAM.2.5.1]
    %@spec [LNAM.2.5.4]
:- pred lnam_2_5_1_highly_restrictive(string::in) is semidet.

    % Succeeds with the reason when the already-NFC name is not a legal DS
    % identifier.
    %
    %@spec [LNAM.2.2.3]
:- pred lnam_2_2_3_check(string::in, string::out) is semidet.

    % Every character is below U+0080. An ill-formed code unit reads as U+FFFD,
    % so a string that passes is well-formed UTF-8 too.
    %
    %@helper
:- pred all_ascii(string::in) is semidet.

%-----------------------------------------------------------------------------%
% Bidi controls in strings and comments -- [LNAM.2.6.3]
%-----------------------------------------------------------------------------%

    %@helper
:- type bidi_fault
    --->    bidi_unterminated(char)
            % Opened inside the literal or comment and still open at its end.

    ;       bidi_unmatched(char).
            % A close with nothing to close.

    %@helper
:- type bidi_result
    --->    bidi_ok
    ;       bidi_bad(bidi_fault, int, int).     % fault, line, column

    % Over the content of one string literal or comment, given where it starts.
    % The stack discipline is UAX #9's, not strict nesting: `RLI LRE PDI` is
    % balanced. `LRM`, `RLM` and `ALM` open no scope.
    %
    %@spec [LNAM.2.6.3]
:- pred lnam_2_6_3_bidi_balance(list(char)::in, int::in, int::in,
                                bidi_result::out) is det.

    % The codepoint and its Unicode name.
    %
    %@helper
:- func bidi_control_name(char) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module array.
:- import_module dsc.unicode.
:- import_module int.
:- import_module map.
:- import_module pair.

%-----------------------------------------------------------------------------%
% Range lookup
%-----------------------------------------------------------------------------%

    %@helper
:- func id_start_array = array(cp_range).
:- pragma memo(id_start_array/0).

id_start_array = array(id_start_ranges).

    %@helper
:- func id_cont_array = array(cp_range).
:- pragma memo(id_cont_array/0).

id_cont_array = array(id_cont_ranges).

    %@helper
:- func script_array = array(script_run).
:- pragma memo(script_array/0).

script_array = array(script_ranges).

    %@helper
:- pred in_ranges(array(cp_range)::in, int::in) is semidet.

in_ranges(A, Cp) :-
    bsearch_range(A, Cp, 0, size(A) - 1).

    %@helper
:- pred bsearch_range(array(cp_range)::in, int::in, int::in, int::in)
    is semidet.

bsearch_range(A, Cp, Lo, Hi) :-
    Lo =< Hi,
    Mid = (Lo + Hi) // 2,
    lookup(A, Mid, r(RLo, RHi)),
    ( if Cp < RLo then
        bsearch_range(A, Cp, Lo, Mid - 1)
    else if Cp > RHi then
        bsearch_range(A, Cp, Mid + 1, Hi)
    else
        true
    ).

lnam_2_2_1_id_start(C) :- in_ranges(id_start_array, to_int(C)).

lnam_2_2_1_id_continue(C) :- in_ranges(id_cont_array, to_int(C)).

script_set(C) = Codes :-
    ( if bsearch_script(script_array, to_int(C), 0,
                        size(script_array) - 1, Found) then
        Codes = Found
    else
        Codes = []
    ).

    %@helper
:- pred bsearch_script(array(script_run)::in, int::in, int::in, int::in,
                       list(string)::out) is semidet.

bsearch_script(A, Cp, Lo, Hi, Out) :-
    Lo =< Hi,
    Mid = (Lo + Hi) // 2,
    lookup(A, Mid, s(RLo, RHi, Codes)),
    ( if Cp < RLo then
        bsearch_script(A, Cp, Lo, Mid - 1, Out)
    else if Cp > RHi then
        bsearch_script(A, Cp, Mid + 1, Hi, Out)
    else
        Out = Codes
    ).

%-----------------------------------------------------------------------------%
% Mixed script -- [LNAM.2.5.1], UAX #39 Highly Restrictive
%-----------------------------------------------------------------------------%

    %@helper
:- func common_code = string.
common_code = "Zyyy".

    %@helper
:- func inherited_code = string.
inherited_code = "Zinh".

    % The three Latin+CJK combinations Highly Restrictive admits beyond a
    % single script: Japanese, Chinese, Korean.
    %
    %@helper
:- func combos = list(list(string)).

combos = [
    ["Bopo", "Hani", "Latn"],
    ["Hang", "Hani", "Latn"],
    ["Hani", "Hira", "Kana", "Latn"]
].

lnam_2_5_1_highly_restrictive(S) :-
    ( if all_ascii(S) then
        % An ASCII name is single-script or script-neutral.
        true
    else
        resolve_scripts(to_char_list(S), no_resolved, [], Resolved, Union),
        script_mix_allowed(Resolved, Union)
    ).

    %@helper
:- pred script_mix_allowed(resolved_scripts::in, list(string)::in)
    is semidet.

script_mix_allowed(Resolved, Union) :-
    (
        Resolved = no_resolved
    ;
        Resolved = resolved(Set),
        (
            Set = [_ | _]
        ;
            Set = [],
            some [Combo] (
                member(Combo, combos),
                subset_of(Union, Combo)
            )
        )
    ).

    %@helper
:- type resolved_scripts
    --->    no_resolved
    ;       resolved(list(string)).

    %@helper
:- pred resolve_scripts(list(char)::in, resolved_scripts::in,
                        list(string)::in, resolved_scripts::out,
                        list(string)::out) is det.

resolve_scripts([], !.R, !.U, !:R, !:U) :-
    !:R = !.R,
    !:U = !.U.
resolve_scripts([C | Cs], R0, U0, R, U) :-
    Scx = script_set(C),
    ( if
        Scx = [_ | _],
        not member(common_code, Scx),
        not member(inherited_code, Scx)
    then
        U1 = merge_codes(U0, Scx),
        (
            R0 = no_resolved,
            R1 = resolved(Scx)
        ;
            R0 = resolved(Prev),
            R1 = resolved(intersect_codes(Prev, Scx))
        )
    else
        U1 = U0,
        R1 = R0
    ),
    resolve_scripts(Cs, R1, U1, R, U).

    %@helper
:- func merge_codes(list(string), list(string)) = list(string).

merge_codes(A, B) = list.sort_and_remove_dups(A ++ B).

    %@helper
:- func intersect_codes(list(string), list(string)) = list(string).

intersect_codes(A, B) =
    list.filter(pred(X::in) is semidet :- list.member(X, B), A).

    %@helper
:- pred subset_of(list(string)::in, list(string)::in) is semidet.

subset_of([], _).
subset_of([X | Xs], Ys) :-
    member(X, Ys),
    subset_of(Xs, Ys).

%-----------------------------------------------------------------------------%
% NFC -- [LNAM.2.4.1]
%-----------------------------------------------------------------------------%

    %@helper
:- func ccc_map = map(int, int).
:- pragma memo(ccc_map/0).

ccc_map = map.from_assoc_list(
    list.map(func(c(Cp, V)) = pair(Cp, V), ccc_table)).

    %@helper
:- func decomp_map = map(int, list(int)).
:- pragma memo(decomp_map/0).

decomp_map = map.from_assoc_list(
    list.map(func(d(Cp, S)) = pair(Cp, S), decomp_table)).

    %@helper
:- func comp_map = map(pair(int, int), int).
:- pragma memo(comp_map/0).

comp_map = map.from_assoc_list(
    list.map(func(p(A, B, Cp)) = pair(pair(A, B), Cp), primary_composites)).

    %@helper
:- func ccc_of(int) = int.

ccc_of(Cp) = ( if map.search(ccc_map, Cp, V) then V else 0 ).

    % An ASCII string is its own NFC.
    %
lnam_2_4_1_nfc(S) = Out :-
    ( if all_ascii(S) then
        Out = S
    else
        Out = nfc_walk(S)
    ).

    %@helper
:- func nfc_walk(string) = string.

nfc_walk(S) = Out :-
    Cps = list.map(to_int, to_char_list(S)),
    Decomposed = condense(list.map(decompose_cp, Cps)),
    Ordered = canonical_order(Decomposed),
    Composed = compose(Ordered),
    Out = from_char_list(list.filter_map(from_int_semidet, Composed)).

    %@helper
:- func from_int_semidet(int) = char.
    %@helper
:- mode from_int_semidet(in) = out is semidet.

from_int_semidet(I) = C :- char.from_int(I, C).

    %@helper
:- func decompose_cp(int) = list(int).

decompose_cp(Cp) =
    ( if hangul_decompose(Cp, Seq) then Seq
    else if map.search(decomp_map, Cp, Seq2) then Seq2
    else [Cp]
    ).

%-----------------------------------------------------------------------------%
% Hangul -- UAX #15 §10.3, algorithmic: `UnicodeData.txt` has no decompositions
%-----------------------------------------------------------------------------%

    %@helper
:- func s_base = int.
s_base = 0xAC00.
    %@helper
:- func l_base = int.
l_base = 0x1100.
    %@helper
:- func v_base = int.
v_base = 0x1161.
    %@helper
:- func t_base = int.
t_base = 0x11A7.
    %@helper
:- func l_count = int.
l_count = 19.
    %@helper
:- func v_count = int.
v_count = 21.
    %@helper
:- func t_count = int.
t_count = 28.
    %@helper
:- func n_count = int.
n_count = v_count * t_count.
    %@helper
:- func s_count = int.
s_count = l_count * n_count.

    %@helper
:- pred hangul_decompose(int::in, list(int)::out) is semidet.

hangul_decompose(S, Seq) :-
    S >= s_base,
    S < s_base + s_count,
    SIndex = S - s_base,
    L = l_base + SIndex // n_count,
    V = v_base + (SIndex mod n_count) // t_count,
    T = t_base + SIndex mod t_count,
    ( if T = t_base then
        Seq = [L, V]
    else
        Seq = [L, V, T]
    ).

    % L+V makes an LV syllable, and LV+T an LVT one.
    %
    %@helper
:- pred hangul_compose(int::in, int::in, int::out) is semidet.

hangul_compose(A, B, S) :-
    ( if
        A >= l_base, A < l_base + l_count,
        B >= v_base, B < v_base + v_count
    then
        S = s_base + ((A - l_base) * v_count + (B - v_base)) * t_count
    else
        A >= s_base, A < s_base + s_count,
        (A - s_base) mod t_count = 0,
        B > t_base, B < t_base + t_count,
        S = A + (B - t_base)
    ).

    %@helper
:- func canonical_order(list(int)) = list(int).

canonical_order([]) = [].
canonical_order([Cp | Cps]) = Out :-
    ( if ccc_of(Cp) = 0 then
        take_nonstarters(Cps, Run, Rest),
        Out = [Cp | sort_by_ccc(Run) ++ canonical_order(Rest)]
    else
        take_nonstarters([Cp | Cps], Run, Rest),
        Out = sort_by_ccc(Run) ++ canonical_order(Rest)
    ).

    %@helper
:- pred take_nonstarters(list(int)::in, list(int)::out, list(int)::out) is det.

take_nonstarters([], [], []).
take_nonstarters([Cp | Cps], Run, Rest) :-
    ( if ccc_of(Cp) = 0 then
        Run = [],
        Rest = [Cp | Cps]
    else
        take_nonstarters(Cps, Run0, Rest),
        Run = [Cp | Run0]
    ).

    % Two marks of equal class keep their written order, which the index keeps.
    %
    %@helper
:- func sort_by_ccc(list(int)) = list(int).

sort_by_ccc(L) = list.map(undecorate,
    list.sort(decorate_with_index(L, 0))).

    %@helper
:- func decorate_with_index(list(int), int) = list(pair(int, pair(int, int))).

decorate_with_index([], _) = [].
decorate_with_index([Cp | Cps], I) =
    [pair(ccc_of(Cp), pair(I, Cp)) | decorate_with_index(Cps, I + 1)].

    %@helper
:- func undecorate(pair(int, pair(int, int))) = int.

undecorate(P) = Cp :-
    P = _ - Inner,
    Inner = _ - Cp.

    %@helper
:- func compose(list(int)) = list(int).

compose([]) = [].
compose([Cp | Cps]) = compose_from(Cp, 0, Cps, []).

    %@helper
:- func compose_from(int, int, list(int), list(int)) = list(int).

compose_from(Starter, _LastCcc, [], Acc) = [Starter | reverse(Acc)].
compose_from(Starter, LastCcc, [C | Cs], Acc) = Out :-
    Ccc = ccc_of(C),
    ( if
        ( LastCcc < Ccc ; LastCcc = 0, Ccc = 0 ),
        ( hangul_compose(Starter, C, H) -> Composed = H
        ; map.search(comp_map, pair(Starter, C), Composed)
        )
    then
        Out = compose_from(Composed, LastCcc, Cs, Acc)
    else if Ccc = 0 then
        Out = [Starter | reverse(Acc)] ++ compose_from(C, 0, Cs, [])
    else
        Out = compose_from(Starter, Ccc, Cs, [C | Acc])
    ).

%-----------------------------------------------------------------------------%

lnam_2_2_3_check(Nfc, Reason) :-
    Chars = to_char_list(Nfc),
    (
        Chars = [],
        Reason = "empty identifier"
    ;
        Chars = [First | Rest],
        ( if not lnam_2_2_1_id_start(First) then
            Reason = "illegal identifier start " ++ codepoint_name(First)
                ++ " (not XID_Start and Identifier_Status=Allowed)"
        else if find_first_match(
            pred(C::in) is semidet :- not lnam_2_2_1_id_continue(C),
            Rest, Bad)
        then
            Reason = "illegal identifier character " ++ codepoint_name(Bad)
                ++ " (not XID_Continue and Identifier_Status=Allowed)"
        else if not lnam_2_5_1_highly_restrictive(Nfc) then
            Reason = "mixed-script identifier rejected "
                ++ "(UAX #39 Highly Restrictive)"
        else
            fail
        )
    ).

all_ascii(S) :-
    string.all_match(ascii_char, S).

    %@helper
:- pred ascii_char(char::in) is semidet.

ascii_char(C) :-
    char.to_int(C) < 0x80.

    %@helper
:- func codepoint_name(char) = string.

codepoint_name(C) = "U+" ++ to_upper(int_to_base_string(to_int(C), 16)).

%-----------------------------------------------------------------------------%
% Bidi controls -- [LNAM.2.6.3]
%-----------------------------------------------------------------------------%
%
% The nine are every codepoint Unicode 16.0 gives a scoping bidi class.

    % `PDF` closes an embedding and `PDI` an isolate.
    %
    %@helper
:- type bidi_scope
    --->    bs_embedding
    ;       bs_isolate.

    % A fault is reported at the opener.
    %
    %@helper
:- type bidi_open
    --->    bidi_open(bidi_scope, char, int, int).

    %@helper
:- pred bidi_opener(char::in, bidi_scope::out) is semidet.

bidi_opener('\x202A\', bs_embedding).   % LRE  LEFT-TO-RIGHT EMBEDDING
bidi_opener('\x202B\', bs_embedding).   % RLE  RIGHT-TO-LEFT EMBEDDING
bidi_opener('\x202D\', bs_embedding).   % LRO  LEFT-TO-RIGHT OVERRIDE
bidi_opener('\x202E\', bs_embedding).   % RLO  RIGHT-TO-LEFT OVERRIDE
bidi_opener('\x2066\', bs_isolate).     % LRI  LEFT-TO-RIGHT ISOLATE
bidi_opener('\x2067\', bs_isolate).     % RLI  RIGHT-TO-LEFT ISOLATE
bidi_opener('\x2068\', bs_isolate).     % FSI  FIRST STRONG ISOLATE

    %@helper
:- func pdf = char.

pdf = '\x202C\'.    % POP DIRECTIONAL FORMATTING

    %@helper
:- func pdi = char.

pdi = '\x2069\'.    % POP DIRECTIONAL ISOLATE

lnam_2_6_3_bidi_balance(Cs, Line, Col, Result) :-
    bidi_walk(Cs, [], Line, Col, Result).

    %@helper
:- pred bidi_walk(list(char)::in, list(bidi_open)::in, int::in, int::in,
                  bidi_result::out) is det.

bidi_walk([], Stack, _, _, Result) :-
    % The outermost still-open control.
    ( if list.last(Stack, bidi_open(_, C, L, Cl)) then
        Result = bidi_bad(bidi_unterminated(C), L, Cl)
    else
        Result = bidi_ok
    ).
bidi_walk([C | Cs], Stack0, Line, Col, Result) :-
    ( if C = '\n' then
        % Only a `"""` reaches this.
        bidi_walk(Cs, Stack0, Line + 1, 0, Result)
    else if bidi_opener(C, Scope) then
        bidi_walk(Cs, [bidi_open(Scope, C, Line, Col) | Stack0],
            Line, Col + 1, Result)
    else if C = pdf then
        ( if Stack0 = [bidi_open(bs_embedding, _, _, _) | Rest] then
            bidi_walk(Cs, Rest, Line, Col + 1, Result)
        else
            % An empty stack, or an isolate on top (UAX #9 X7).
            Result = bidi_bad(bidi_unmatched(C), Line, Col)
        )
    else if C = pdi then
        ( if bidi_pop_to_isolate(Stack0, Rest) then
            bidi_walk(Cs, Rest, Line, Col + 1, Result)
        else
            Result = bidi_bad(bidi_unmatched(C), Line, Col)
        )
    else
        bidi_walk(Cs, Stack0, Line, Col + 1, Result)
    ).

    % UAX #9 X6a: a `PDI` ends its isolate and every embedding inside it. Fails
    % when no isolate is open.
    %
    %@helper
:- pred bidi_pop_to_isolate(list(bidi_open)::in, list(bidi_open)::out)
    is semidet.

bidi_pop_to_isolate([bidi_open(Scope, _, _, _) | Rest], Out) :-
    (
        Scope = bs_isolate,
        Out = Rest
    ;
        Scope = bs_embedding,
        bidi_pop_to_isolate(Rest, Out)
    ).

bidi_control_name(C) = codepoint_name(C) ++ " " ++ Name :-
    ( if C = '\x202A\' then Name = "LEFT-TO-RIGHT EMBEDDING"
    else if C = '\x202B\' then Name = "RIGHT-TO-LEFT EMBEDDING"
    else if C = '\x202C\' then Name = "POP DIRECTIONAL FORMATTING"
    else if C = '\x202D\' then Name = "LEFT-TO-RIGHT OVERRIDE"
    else if C = '\x202E\' then Name = "RIGHT-TO-LEFT OVERRIDE"
    else if C = '\x2066\' then Name = "LEFT-TO-RIGHT ISOLATE"
    else if C = '\x2067\' then Name = "RIGHT-TO-LEFT ISOLATE"
    else if C = '\x2068\' then Name = "FIRST STRONG ISOLATE"
    else if C = '\x2069\' then Name = "POP DIRECTIONAL ISOLATE"
    else Name = "bidi control"
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.uniname.
%-----------------------------------------------------------------------------%

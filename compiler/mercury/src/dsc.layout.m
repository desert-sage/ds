% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.layout -- the indentation pass: tokens in, tokens + INDENT/DEDENT out.
%
% A blank line cannot be expressed in a `source_line`, so it affects nothing
% ([LLEX.5.2]). Inside open brackets `NEWLINE` is suppressed and indentation is
% not tracked ([LLEX.7.3], [LLEX.7.5.5]). A non-multiple rise is [LLEX.6.4]'s
% error and a non-matching fall [LLEX.6.3]'s.
%-----------------------------------------------------------------------------%

:- module dsc.layout.
:- interface.

:- import_module dsc.token.

:- import_module list.

%-----------------------------------------------------------------------------%

    % One physical line that produced at least one token. `sl_indent` is the
    % leading-space count ([LLEX.6.1]).
    %
    %@helper
:- type source_line
    --->    source_line(
                sl_indent :: int,
                sl_tokens :: list(positioned)
            ).

    %@helper
:- type layout_error
    --->    le_inconsistent_indent(int, int)
            % Rise that is not a multiple of 4 from the enclosing indent
            % [LLEX.6.4]. Carries (found, enclosing).

    ;       le_inconsistent_dedent(int)
            % Fall to a column matching no enclosing block [LLEX.6.3].

    ;       le_mismatched_closer(token, token)
            % [LLEX.7.5.3]. Carries (found, expected).

    ;       le_unexpected_closer(token)
            % A closer with no open group at all.

    ;       le_unclosed_bracket(token)
            % Still open at EOF. Carries the expected closer.

    ;       le_layout_token_from_lexer(token).
            % The lexer emitted `newline`, `indent` or `dedent`: not an author
            % error.

    %@helper
:- type layout_result
    --->    lay_ok(list(positioned))
    ;       lay_error(layout_error, pos).

    %@spec [LLEX.6.2]
:- pred llex_6_2_layout(list(source_line)::in, layout_result::out) is det.

    %@helper
:- func describe_error(layout_error) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module string.

%-----------------------------------------------------------------------------%

    % A token this pass invented: zero width.
    %
    %@helper
:- func synthetic(token, pos) = positioned.

synthetic(Tok, Pos) = positioned(Tok, Pos, Pos).

    % The indent stack, top first, 0 at the bottom; the open bracket groups,
    % innermost first.
    %
    %@helper
:- type lstate
    --->    lstate(
                ls_stack :: list(int),
                ls_open  :: list(open_group)
            ).

    %@helper
:- type open_group
    --->    open_group(
                og_close :: token,
                og_pos   :: pos
            ).

%-----------------------------------------------------------------------------%

llex_6_2_layout(Lines, Result) :-
    llex_7_2_lay_lines(Lines, lstate([0], []), pos(1, 0), [], Result).

    %@spec [LLEX.7.1]
    %@spec [LLEX.7.2]
    %@spec [LLEX.7.3]
    %@spec [LLEX.7.4]
    %@spec [LLEX.7.5.2]
    %@spec [LLEX.7.5.5]
:- pred llex_7_2_lay_lines(list(source_line)::in, lstate::in, pos::in,
                  list(positioned)::in, layout_result::out) is det.

llex_7_2_lay_lines([], St, LastPos, Rev0, Result) :-
    (
        St ^ ls_open = [OG | _],
        Result = lay_error(le_unclosed_bracket(OG ^ og_close), OG ^ og_pos)
    ;
        St ^ ls_open = [],
        llex_6_5_emit_dedents(St ^ ls_stack, LastPos, Rev0, Rev),
        Result = lay_ok(reverse(Rev))
    ).
llex_7_2_lay_lines([Line | Lines], St0, LastPos0, Rev0, Result) :-
    Line = source_line(Indent, Toks),
    (
        Toks = [],
        % Unreachable: the lexer emits no line for a blank line.
        llex_7_2_lay_lines(Lines, St0, LastPos0, Rev0, Result)
    ;
        Toks = [First | _],
        FirstPos = First ^ tk_pos,
        ( if St0 ^ ls_open = [] then
            llex_6_3_apply_indent(Indent, FirstPos, St0 ^ ls_stack, IndentRes)
        else
            IndentRes = ind_ok(St0 ^ ls_stack, [])
        ),
        (
            IndentRes = ind_error(Err, EPos),
            Result = lay_error(Err, EPos)
        ;
            IndentRes = ind_ok(Stack1, Layout),
            llex_7_5_3_scan_tokens(Toks, St0 ^ ls_open, ScanRes),
            (
                ScanRes = scan_error(Err2, EPos2),
                Result = lay_error(Err2, EPos2)
            ;
                ScanRes = scan_ok(Open1),
                St1 = lstate(Stack1, Open1),
                % INDENT/DEDENT come before the line's first token ([LLEX.7.4]).
                Rev1 = reverse(Layout) ++ Rev0,
                Rev2 = reverse(Toks) ++ Rev1,
                LastTokPos = last_pos(Toks, FirstPos),
                (
                    Open1 = [],
                    Rev3 = [synthetic(newline, LastTokPos) | Rev2]
                ;
                    Open1 = [_ | _],
                    Rev3 = Rev2
                ),
                llex_7_2_lay_lines(Lines, St1, LastTokPos, Rev3, Result)
            )
        )
    ).

%-----------------------------------------------------------------------------%
% Indentation
%-----------------------------------------------------------------------------%

    %@helper
:- type indent_result
    --->    ind_ok(list(int), list(positioned))
    ;       ind_error(layout_error, pos).

    %@spec [LLEX.6.1]
    %@spec [LLEX.6.3]
    %@spec [LLEX.6.4]
    %@spec [LGRA.2.3.1]
:- pred llex_6_3_apply_indent(int::in, pos::in, list(int)::in, indent_result::out)
    is det.

llex_6_3_apply_indent(Indent, Pos, Stack, Result) :-
    (
        Stack = [],
        % Cannot happen: 0 is pushed at construction and never popped.
        Result = ind_ok([0], [])
    ;
        Stack = [Top | _],
        ( if Indent = Top then
            Result = ind_ok(Stack, [])
        else if Indent > Top then
            Delta = Indent - Top,
            ( if Delta mod 4 = 0 then
                N = Delta / 4,
                push_levels(N, Top, Stack, Stack1),
                Result = ind_ok(Stack1, duplicate(N, synthetic(indent, Pos)))
            else
                Result = ind_error(le_inconsistent_indent(Indent, Top), Pos)
            )
        else
            pop_to(Indent, Pos, Stack, [], Result)
        )
    ).

    %@helper
:- pred push_levels(int::in, int::in, list(int)::in, list(int)::out) is det.

push_levels(N, From, !Stack) :-
    ( if N =< 0 then
        true
    else
        Next = From + 4,
        !:Stack = [Next | !.Stack],
        push_levels(N - 1, Next, !Stack)
    ).

    %@helper
:- pred pop_to(int::in, pos::in, list(int)::in, list(positioned)::in,
               indent_result::out) is det.

pop_to(Indent, Pos, Stack, Acc, Result) :-
    (
        Stack = [],
        Result = ind_error(le_inconsistent_dedent(Indent), Pos)
    ;
        Stack = [Top | Rest],
        ( if Indent = Top then
            Result = ind_ok(Stack, reverse(Acc))
        else if Indent < Top then
            pop_to(Indent, Pos, Rest, [synthetic(dedent, Pos) | Acc], Result)
        else
            Result = ind_error(le_inconsistent_dedent(Indent), Pos)
        )
    ).

    %@spec [LLEX.6.5]
:- pred llex_6_5_emit_dedents(list(int)::in, pos::in,
                     list(positioned)::in, list(positioned)::out) is det.

llex_6_5_emit_dedents([], _, !Rev).
llex_6_5_emit_dedents([Level | Rest], Pos, !Rev) :-
    ( if Level > 0 then
        !:Rev = [synthetic(dedent, Pos) | !.Rev],
        llex_6_5_emit_dedents(Rest, Pos, !Rev)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Bracket tracking
%-----------------------------------------------------------------------------%

    %@helper
:- type scan_result
    --->    scan_ok(list(open_group))
    ;       scan_error(layout_error, pos).

    %@spec [LLEX.7.5.3]
    %@spec [LLEX.7.5.4]
    %@spec [LLEX.7.5.6]
:- pred llex_7_5_3_scan_tokens(list(positioned)::in, list(open_group)::in,
                    scan_result::out) is det.

llex_7_5_3_scan_tokens([], Open, scan_ok(Open)).
llex_7_5_3_scan_tokens([P | Ps], Open, Result) :-
    P = positioned(Tok, Pos, _),
    ( if layout_token(Tok) then
        Result = scan_error(le_layout_token_from_lexer(Tok), Pos)
    else if llex_7_5_3_bracket_open(Tok, Closer) then
        llex_7_5_3_scan_tokens(Ps, [open_group(Closer, Pos) | Open], Result)
    else if llex_7_5_3_bracket_close(Tok) then
        (
            Open = [],
            Result = scan_error(le_unexpected_closer(Tok), Pos)
        ;
            Open = [OG | Rest],
            ( if OG ^ og_close = Tok then
                llex_7_5_3_scan_tokens(Ps, Rest, Result)
            else
                Result = scan_error(
                    le_mismatched_closer(Tok, OG ^ og_close), Pos)
            )
        )
    else
        llex_7_5_3_scan_tokens(Ps, Open, Result)
    ).

%-----------------------------------------------------------------------------%

    %@helper
:- func last_pos(list(positioned), pos) = pos.

last_pos([], Default) = Default.
last_pos([P | Ps], _) = last_pos(Ps, P ^ tk_pos).

%-----------------------------------------------------------------------------%

describe_error(le_inconsistent_indent(Found, Enclosing)) =
    "inconsistent indentation: expected multiple of 4 from column "
        ++ from_int(Enclosing) ++ ", found column " ++ from_int(Found).
describe_error(le_inconsistent_dedent(Found)) =
    "inconsistent dedent: column " ++ from_int(Found)
        ++ " does not match any enclosing block".
describe_error(le_mismatched_closer(Found, Expected)) =
    "mismatched bracket: found " ++ describe(Found)
        ++ ", expected " ++ describe(Expected).
describe_error(le_unexpected_closer(Found)) =
    "unmatched " ++ describe(Found) ++ ": no group is open".
describe_error(le_unclosed_bracket(Expected)) =
    "unclosed bracket group: expected " ++ describe(Expected)
        ++ " before end of file".
describe_error(le_layout_token_from_lexer(Tok)) =
    "internal: the lexer emitted the layout token " ++ describe(Tok).

%-----------------------------------------------------------------------------%
:- end_module dsc.layout.
%-----------------------------------------------------------------------------%

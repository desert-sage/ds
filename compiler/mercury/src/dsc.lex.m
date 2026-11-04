% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.lex -- bytes to tokens, grouped into lines for dsc.layout.
%
% Blank lines are dropped here, so the layout pass is never handed one.
%
% Every identifier decision goes through `dsc.uniname`, never `char.is_alpha` and
% its siblings, which follow whatever Unicode `mmc` was built with.
%
% String content is kept raw: interpolation, escapes and `cleandoc` are its
% consumers'.
%-----------------------------------------------------------------------------%

:- module dsc.lex.
:- interface.

:- import_module dsc.layout.
:- import_module dsc.token.

:- import_module char.

:- import_module list.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type lex_error
    --->    lx_lone_bang
    ;       lx_ellipsis
    ;       lx_bad_char(char)
    ;       lx_lone_cr
    ;       lx_unterminated_string
    ;       lx_unterminated_triple
    ;       lx_bad_numeric_suffix(string, string)
            % The numeric text and the suffix.
    ;       lx_leading_underscore
            % A `_` that no identifier character follows.
    ;       lx_unterminated_regex
    ;       lx_bare_fraction
    ;       lx_underscore_placement(string)
    ;       lx_based_unit(string)
    ;       lx_int_out_of_range(string)
    ;       lx_float_out_of_range(string)
    ;       lx_bad_unit_char(char)
    ;       lx_bare_imaginary(string)
            % `5_i`. `5i`, with no separator, is `lx_complex_literal`.
    ;       lx_complex_literal(string)
            % The driver reports it as `DS_VALIDATE_COMPLEX_NOT_IN_V1`.
    ;       lx_bidi_unterminated(bidi_where, char)
    ;       lx_bidi_unmatched(bidi_where, char)
    ;       lx_ill_formed_utf8
    ;       lx_bad_identifier(string, string).
            % The NFC name and `dsc.uniname`'s reason.

    %@helper
:- type bidi_where
    --->    bw_string
    ;       bw_comment.

    %@helper
:- type lex_result
    --->    lex_ok(list(source_line))
    ;       lex_error(lex_error, pos).

    %@spec [LLEX.5.4]
:- pred llex_5_4_lex(string::in, lex_result::out) is det.

    % What the layout pass never sees and `ds_ast` needs: every comment, and the
    % blank lines between content lines. The compiler proper does not read it.
    %
    %@helper
:- type trivia
    --->    trivia(
                tv_comments   :: list(comment),
                    % In source order.
                tv_blank_runs :: list(blank_run)
                    % In source order, and only runs of one or more.
            ).

    % One comment: its text from the first `#` to the end of the line, as
    % written -- every `#` of a `##` banner kept, a CRLF's `\r` not -- and
    % where it sits.
    %
    %@helper
:- type comment
    --->    comment(
                cm_text      :: string,
                cm_pos       :: pos,
                    % The first `#`.
                cm_placement :: comment_placement
            ).

    %@helper
:- type comment_placement
    --->    cp_own_line
            % Nothing but the comment on its line.
    ;       cp_trailing.
            % After a token on the same line.

    % `br_count` blank lines -- nothing on them, not even a comment -- end
    % just before line `br_line`. A run at end of file names the line after
    % the last.
    %
    %@helper
:- type blank_run
    --->    blank_run(
                br_line  :: int,
                br_count :: int
            ).

    %@helper
:- type lex_trivia_result
    --->    lex_trivia_ok(list(source_line), trivia)
    ;       lex_trivia_error(lex_error, pos).

    % `llex_5_4_lex`, and the trivia beside it. Same lines, same errors.
    %
    %@spec [LLEX.5.4]
:- pred llex_5_4_lex_trivia(string::in, lex_trivia_result::out) is det.

    %@helper
:- func describe_lex_error(lex_error) = string.

    % The first byte of `Units` not part of a well-formed UTF-8 sequence, as the
    % scanner's line and column. Exported because a test can spell the bytes and
    % not an ill-formed `string` literal.
    %
    %@spec [LLEX.1.1]
:- pred llex_1_1_first_ill_formed(list(int)::in, pos::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.uniname.
:- import_module ds.
:- import_module ds.float_text.
:- import_module ds.i64.
:- import_module bool.
:- import_module int.
:- import_module maybe.
:- use_module dsc.exact.
:- use_module float.

%-----------------------------------------------------------------------------%

    % The scanner's state: the remaining characters, the position of the first
    % of them, the tokens of the line being built (reversed), the leading-space
    % count of that line, and the completed lines (reversed). The last four are
    % the trivia: comments and blank runs so far (both reversed), whether the
    % line being built holds a comment, and the blank lines since the last line
    % that held anything.
    %
    %@helper
:- type lstate
    --->    lstate(
                lx_line     :: int,
                lx_col      :: int,
                lx_indent   :: int,
                lx_cur      :: list(positioned),
                lx_lines    :: list(source_line),
                lx_comments :: list(comment),
                lx_runs     :: list(blank_run),
                lx_commented :: bool,
                lx_blank    :: int
            ).

llex_5_4_lex(Src, Result) :-
    llex_5_4_lex_trivia(Src, Full),
    (
        Full = lex_trivia_ok(Lines, _),
        Result = lex_ok(Lines)
    ;
        Full = lex_trivia_error(Error, Pos),
        Result = lex_error(Error, Pos)
    ).

llex_5_4_lex_trivia(Src, Result) :-
    ( if llex_1_1_ill_formed(Src, Bad) then
        Result = lex_trivia_error(lx_ill_formed_utf8, Bad)
    else
        Chars = to_char_list(Src),
        St0 = lstate(1, 0, 0, [], [], [], [], no, 0),
        scan_indent(Chars, St0, Step),
        llex_8_2_3_scan_loop(Step, Result)
    ).

    % What one step of the scanner leaves to do: scan on from these
    % characters, in the middle of a line, or nothing, with the result.
    %
    %@helper
:- type scan_step
    --->    in_line(list(char), lstate)
    ;       scanned(lex_trivia_result).

    % The only place the scan continues. One self-recursive predicate is a loop
    % on every architecture, where a tail call between predicates depends on the
    % C compiler. So each scanner below returns what is left, as a `scan_step`,
    % and none calls the next; test_cli's `cases_large` holds this.
    %
    %@spec [LLEX.8.2.3]
:- pred llex_8_2_3_scan_loop(scan_step::in, lex_trivia_result::out) is det.

llex_8_2_3_scan_loop(Step, Result) :-
    (
        Step = in_line(Cs, St),
        llex_8_2_3_scan_line(Cs, St, Next),
        llex_8_2_3_scan_loop(Next, Result)
    ;
        Step = scanned(Result)
    ).

    % The whole file, on the code units before any character is decoded:
    % `io.read_named_file_as_string` does not guarantee a well-formed string, and
    % `to_char_list` would read an ill-formed byte as a U+FFFD. Well-formed is
    % Unicode's Table 3-7.
    %
    %@spec [LLEX.1.1]
    %@spec [LNAM.2.7.1]
:- pred llex_1_1_ill_formed(string::in, pos::out) is semidet.

llex_1_1_ill_formed(Src, Pos) :-
    % An ill-formed byte reads as U+FFFD, so an all-ASCII file needs no walk.
    not all_ascii(Src),
    string.to_utf8_code_unit_list(Src, Units),
    llex_1_1_first_ill_formed(Units, Pos).

llex_1_1_first_ill_formed(Units, Pos) :-
    first_ill_formed(Units, 1, 0, Pos).

    %@helper
:- pred first_ill_formed(list(int)::in, int::in, int::in, pos::out)
    is semidet.

first_ill_formed([U | Us], Line, Col, Pos) :-
    ( if utf8_sequence(U, Us, Rest) then
        ( if U = 0x0A then
            first_ill_formed(Rest, Line + 1, 0, Pos)
        else
            first_ill_formed(Rest, Line, Col + 1, Pos)
        )
    else
        Pos = pos(Line, Col)
    ).

    %@helper
:- pred utf8_sequence(int::in, list(int)::in, list(int)::out) is semidet.

utf8_sequence(U, Us, Rest) :-
    ( if U =< 0x7F then
        Rest = Us
    else if U >= 0xC2, U =< 0xDF then
        utf8_cont(Us, 0x80, 0xBF, Rest)
    else if U = 0xE0 then
        utf8_cont(Us, 0xA0, 0xBF, R1),
        utf8_cont(R1, 0x80, 0xBF, Rest)
    else if ( U >= 0xE1, U =< 0xEC ; U >= 0xEE, U =< 0xEF ) then
        utf8_cont(Us, 0x80, 0xBF, R1),
        utf8_cont(R1, 0x80, 0xBF, Rest)
    else if U = 0xED then
        % The surrogates are this lead with a second byte of A0..BF.
        utf8_cont(Us, 0x80, 0x9F, R1),
        utf8_cont(R1, 0x80, 0xBF, Rest)
    else if U = 0xF0 then
        utf8_cont(Us, 0x90, 0xBF, R1),
        utf8_cont(R1, 0x80, 0xBF, R2),
        utf8_cont(R2, 0x80, 0xBF, Rest)
    else if U >= 0xF1, U =< 0xF3 then
        utf8_cont(Us, 0x80, 0xBF, R1),
        utf8_cont(R1, 0x80, 0xBF, R2),
        utf8_cont(R2, 0x80, 0xBF, Rest)
    else
        U = 0xF4,
        utf8_cont(Us, 0x80, 0x8F, R1),
        utf8_cont(R1, 0x80, 0xBF, R2),
        utf8_cont(R2, 0x80, 0xBF, Rest)
    ).

    %@helper
:- pred utf8_cont(list(int)::in, int::in, int::in, list(int)::out)
    is semidet.

utf8_cont([B | Bs], Lo, Hi, Bs) :-
    B >= Lo,
    B =< Hi.

    %@helper
:- func here(lstate) = pos.

here(St) = pos(St ^ lx_line, St ^ lx_col).

%-----------------------------------------------------------------------------%
% Line starts
%-----------------------------------------------------------------------------%

    %@helper
:- pred scan_indent(list(char)::in, lstate::in, scan_step::out) is det.

scan_indent(Cs, !.St, Step) :-
    count_spaces(Cs, 0, N, Rest),
    !St ^ lx_indent := N,
    !St ^ lx_col := N,
    Step = in_line(Rest, !.St).

    %@helper
:- pred count_spaces(list(char)::in, int::in, int::out, list(char)::out)
    is det.

count_spaces([], N, N, []).
count_spaces([C | Cs], N0, N, Rest) :-
    ( if C = ' ' then
        count_spaces(Cs, N0 + 1, N, Rest)
    else
        N = N0,
        Rest = [C | Cs]
    ).

    % A line whose accumulator is empty is blank, and is dropped.
    %
    %@spec [LLEX.5.1]
    %@spec [LLEX.5.2]
    %@spec [LLEX.5.3]
    %@spec [LLEX.6.6.1]
    %@spec [LGRA.2.2.3]
:- pred llex_5_2_end_line(list(char)::in, lstate::in, scan_step::out) is det.

llex_5_2_end_line(Cs, !.St, Result) :-
    (
        !.St ^ lx_cur = [],
        true
    ;
        !.St ^ lx_cur = [_ | _],
        Line = source_line(!.St ^ lx_indent, reverse(!.St ^ lx_cur)),
        !St ^ lx_lines := [Line | !.St ^ lx_lines]
    ),
    blank_run_at_line_end(!St),
    !St ^ lx_cur := [],
    !St ^ lx_commented := no,
    !St ^ lx_line := !.St ^ lx_line + 1,
    !St ^ lx_col := 0,
    (
        Cs = [],
        close_blank_run(!St),
        Trivia = trivia(reverse(!.St ^ lx_comments), reverse(!.St ^ lx_runs)),
        Result = scanned(lex_trivia_ok(reverse(!.St ^ lx_lines), Trivia))
    ;
        Cs = [_ | _],
        scan_indent(Cs, !.St, Result)
    ).

    % Any line with a token or a comment closes the run, against the line it
    % precedes.
    %
    %@helper
:- pred blank_run_at_line_end(lstate::in, lstate::out) is det.

blank_run_at_line_end(!St) :-
    ( if !.St ^ lx_cur = [], !.St ^ lx_commented = no then
        !St ^ lx_blank := !.St ^ lx_blank + 1
    else
        close_blank_run(!St)
    ).

    %@helper
:- pred close_blank_run(lstate::in, lstate::out) is det.

close_blank_run(!St) :-
    N = !.St ^ lx_blank,
    ( if N > 0 then
        !St ^ lx_runs := [blank_run(!.St ^ lx_line, N) | !.St ^ lx_runs],
        !St ^ lx_blank := 0
    else
        true
    ).

%-----------------------------------------------------------------------------%
% The scanner
%-----------------------------------------------------------------------------%

    %@helper
:- pred emit(token::in, int::in, list(char)::in, lstate::in, scan_step::out)
    is det.

emit(Tok, Width, Rest, St0, Result) :-
    St0 = lstate(Line, Col, Indent, Cur, Lines, Comments, Runs, Commented,
        Blank),
    % `Width` is the source spelling's: `0x2A` and `42` both lex to `int_lit(42)`.
    End = pos(Line, Col + Width),
    St = lstate(Line, Col + Width, Indent,
        [positioned(Tok, pos(Line, Col), End) | Cur], Lines, Comments, Runs,
        Commented, Blank),
    Result = in_line(Rest, St).

    % A tab falls to `lx_bad_char`, which is its refusal.
    %
    %@spec [LLEX.8.2.3]
    %@spec [LGRA.2.2.1]
    %@spec [LGRA.2.2.2]
    %@spec [LGRA.2.4.1]
    %@spec [LGRA.2.4.2]
    %@spec [LGRA.2.4.3]
:- pred llex_8_2_3_scan_line(list(char)::in, lstate::in, scan_step::out) is det.

llex_8_2_3_scan_line([], St, Result) :-
    llex_5_2_end_line([], St, Result).
llex_8_2_3_scan_line([C | Cs], !.St, Result) :-
    ( if C = '\n' then
        llex_5_2_end_line(Cs, !.St, Result)
    else if C = '\r' then
        ( if Cs = ['\n' | _] then
            !St ^ lx_col := !.St ^ lx_col + 1,
            llex_8_2_3_scan_line(Cs, !.St, Result)
        else
            Result = scanned(lex_trivia_error(lx_lone_cr, here(!.St)))
        )
    else if C = ' ' then
        % A run of spaces moves the column once, so one state, not one per space.
        count_spaces(Cs, 1, N, Rest),
        !St ^ lx_col := !.St ^ lx_col + N,
        llex_8_2_3_scan_line(Rest, !.St, Result)
    else if C = '#' then
        % [LNAM.2.6.3] applies to comment content, so it is checked for balance.
        skip_to_eol(Cs, Text, Rest),
        lnam_2_6_3_bidi_check(bw_comment, Text, !.St ^ lx_line,
            !.St ^ lx_col + 1, Bidi),
        (
            Bidi = yes(Err),
            Result = scanned(Err)
        ;
            Bidi = no,
            (
                !.St ^ lx_cur = [],
                Placement = cp_own_line
            ;
                !.St ^ lx_cur = [_ | _],
                Placement = cp_trailing
            ),
            Comment = comment(comment_text(Text), here(!.St), Placement),
            !St ^ lx_comments := [Comment | !.St ^ lx_comments],
            !St ^ lx_commented := yes,
            % `skip_to_eol` leaves the `\n` in `Rest`, and `llex_5_2_end_line`
            % takes the characters after it.
            ( if Rest = ['\n' | AfterNewline] then
                llex_5_2_end_line(AfterNewline, !.St, Result)
            else
                llex_5_2_end_line(Rest, !.St, Result)
            )
        )
    else if C = '"' then
        llex_8_3_3_scan_string(Cs, !.St, Result)
    else if is_digit(C) then
        llex_11_3_1_scan_number([C | Cs], !.St, Result)
    else if llex_10_4_ascii_id_start(C) then
        llex_10_4_scan_ident([C | Cs], !.St, Result)
    else if llex_10_2_glyph_start(C) then
        % No lexer mode: `type_sym` is emitted wherever a glyph appears, and only
        % `dsc.parse.take_type` accepts it.
        llex_10_4_scan_ident([C | Cs], !.St, Result)
    else if
        C = ('_'),
        Cs = [D | _],
        lnam_2_2_1_ascii_id_cont(D)
    then
        llex_10_4_scan_ident([C | Cs], !.St, Result)
    else if C = ('_') then
        Result = scanned(lex_trivia_error(lx_leading_underscore, here(!.St)))
    else if C = ('.'), starts_digit(Cs) then
        Result = scanned(lex_trivia_error(lx_bare_fraction, here(!.St)))
    else if C = ('.'), Cs = ['.', '.' | _] then
        % Before `punct`, which would take `..` and leave a stray `.`.
        Result = scanned(lex_trivia_error(lx_ellipsis, here(!.St)))
    else if C = ('/'), after_match_operator(!.St) then
        lreg_6_1_scan_regex(Cs, !.St, Result)
    else if llex_8_1_2_punct(C, Cs, Tok, Width, Rest) then
        emit(Tok, Width, Rest, !.St, Result)
    else if C = ('!') then
        Result = scanned(lex_trivia_error(lx_lone_bang, here(!.St)))
    else
        Result = scanned(lex_trivia_error(lx_bad_char(C), here(!.St)))
    ).

    % The format and bidi controls [LNAM.2.6] has its own diagnostics for, and
    % the byte-order mark [LLEX.1.2] refuses as an unexpected character.
    %
    %@helper
:- pred invisible_control(char::in) is semidet.

invisible_control(C) :-
    Code = char.to_int(C),
    ( Code >= 0x200B, Code =< 0x200F
    ; Code >= 0x202A, Code =< 0x202E
    ; Code >= 0x2060, Code =< 0x2069
    ; Code = 0xFEFF
    ).

    %@helper
:- pred after_match_operator(lstate::in) is semidet.

after_match_operator(St) :-
    St ^ lx_cur = [Prev | _],
    Tok = Prev ^ tk_tok,
    ( Tok = match_op
    ; Tok = nmatch_op
    ).

    % Escape pairs are carried through as written: the pattern is RE2's to read.
    %
    %@spec [LREG.6.1]
    %@spec [LREG.6.2]
    %@spec [LREG.6.3]
    %@spec [LREG.6.4]
    %@spec [LREG.6.5]
    %@spec [LREG.5.1]
    %@spec [LREG.10.8]
:- pred lreg_6_1_scan_regex(list(char)::in, lstate::in, scan_step::out) is det.

lreg_6_1_scan_regex(Cs, St, Result) :-
    ( if take_regex_body(Cs, [], Body, AfterClose) then
        take_regex_flags(AfterClose, [], Flags, Rest),
        Width = 2 + list.length(Body) + list.length(Flags),
        emit(regex_lit(string.from_char_list(Body),
            string.from_char_list(Flags)), Width, Rest, St, Result)
    else
        Result = scanned(lex_trivia_error(lx_unterminated_regex, here(St)))
    ).

    %@helper
:- pred take_regex_body(list(char)::in, list(char)::in, list(char)::out,
                        list(char)::out) is semidet.

take_regex_body([C | Cs], Acc, Body, Rest) :-
    ( if C = ('/') then
        Body = list.reverse(Acc),
        Rest = Cs
    else if C = ('\\'), Cs = [Escaped | Cs1], Escaped \= ('\n') then
        take_regex_body(Cs1, [Escaped, C | Acc], Body, Rest)
    else
        C \= ('\n'),
        take_regex_body(Cs, [C | Acc], Body, Rest)
    ).

    %@helper
:- pred take_regex_flags(list(char)::in, list(char)::in, list(char)::out,
                         list(char)::out) is det.

take_regex_flags([], Acc, list.reverse(Acc), []).
take_regex_flags([C | Cs], Acc, Flags, Rest) :-
    ( if char.is_alpha(C) then
        take_regex_flags(Cs, [C | Acc], Flags, Rest)
    else
        Flags = list.reverse(Acc),
        Rest = [C | Cs]
    ).

    %@helper
:- pred skip_to_eol(list(char)::in, list(char)::out, list(char)::out) is det.

skip_to_eol(Cs, Text, Rest) :-
    skip_to_eol_acc(Cs, [], RevText, Rest),
    Text = list.reverse(RevText).

    %@helper
:- pred skip_to_eol_acc(list(char)::in, list(char)::in, list(char)::out,
                        list(char)::out) is det.

skip_to_eol_acc([], Acc, Acc, []).
skip_to_eol_acc([C | Cs], Acc, RevText, Rest) :-
    ( if C = '\n' then
        RevText = Acc,
        Rest = [C | Cs]
    else
        skip_to_eol_acc(Cs, [C | Acc], RevText, Rest)
    ).

    % A CRLF file's `\r` is line ending, not comment.
    %
    %@helper
:- func comment_text(list(char)) = string.

comment_text(Text) = "#" ++ from_char_list(Chars) :-
    ( if list.split_last(Text, Init, '\r') then
        Chars = Init
    else
        Chars = Text
    ).

%-----------------------------------------------------------------------------%
% Bidi balance -- [LNAM.2.6.3]
%-----------------------------------------------------------------------------%

    % `no` for content that balances.
    %
    %@spec [LNAM.2.6.3]
:- pred lnam_2_6_3_bidi_check(bidi_where::in, list(char)::in, int::in,
                              int::in, maybe(lex_trivia_result)::out) is det.

lnam_2_6_3_bidi_check(Where, Content, Line, Col, Out) :-
    lnam_2_6_3_bidi_balance(Content, Line, Col, Balance),
    (
        Balance = bidi_ok,
        Out = no
    ;
        Balance = bidi_bad(bidi_unterminated(C), L, Cl),
        Out = yes(lex_trivia_error(lx_bidi_unterminated(Where, C), pos(L, Cl)))
    ;
        Balance = bidi_bad(bidi_unmatched(C), L, Cl),
        Out = yes(lex_trivia_error(lx_bidi_unmatched(Where, C), pos(L, Cl)))
    ).

    % Every bidi control is past ASCII, so ASCII content needs no walk.
    %
    %@helper
:- pred string_bidi_check(string::in, int::in, int::in,
                          maybe(lex_trivia_result)::out) is det.

string_bidi_check(Text, Line, Col, Out) :-
    ( if all_ascii(Text) then
        Out = no
    else
        lnam_2_6_3_bidi_check(bw_string, to_char_list(Text), Line, Col, Out)
    ).

%-----------------------------------------------------------------------------%
% Punctuation -- longest match [LLEX.8.1.1]
%-----------------------------------------------------------------------------%

    % Longest match is `llex_8_1_2_punct` trying this table before `punct1`:
    % overlapping clauses would be nondet.
    %
    %@spec [LLEX.8.1.1]
    %@spec [LLEX.8.3.2]
    %@spec [LGRA.2.10.2]
    %@spec [LGRA.2.10.4]
:- pred llex_8_1_1_punct2(char::in, char::in, token::out) is semidet.

llex_8_1_1_punct2('-', '>', arrow).
llex_8_1_1_punct2('*', '*', star2).
llex_8_1_1_punct2('/', '/', slash2).
llex_8_1_1_punct2('<', '=', le).
llex_8_1_1_punct2('<', '<', shl).
llex_8_1_1_punct2('>', '=', ge).
llex_8_1_1_punct2('>', '>', shr).
llex_8_1_1_punct2('=', '=', eq).
llex_8_1_1_punct2('!', '=', ne).
llex_8_1_1_punct2('!', '~', nmatch_op).
llex_8_1_1_punct2(':', ':', coloncolon).
llex_8_1_1_punct2('?', '?', question2).
llex_8_1_1_punct2('.', '.', dotdot).

    % `assign` and `at` have no production: lexed so the parser can name them.
    %
    %@spec [LLEX.8.2.1]
    %@spec [LLEX.8.2.2]
    %@spec [LLEX.8.3.1]
    %@spec [LGRA.2.10.1]
    %@spec [LGRA.2.10.3]
:- pred llex_8_3_1_punct1(char::in, token::out) is semidet.

llex_8_3_1_punct1('+', plus).
llex_8_3_1_punct1('-', minus).
llex_8_3_1_punct1('*', star).
llex_8_3_1_punct1('/', slash).
llex_8_3_1_punct1('%', percent).
llex_8_3_1_punct1('&', amp).
llex_8_3_1_punct1('|', pipe).
llex_8_3_1_punct1('^', caret).
llex_8_3_1_punct1('~', match_op).
llex_8_3_1_punct1('<', lt).
llex_8_3_1_punct1('>', gt).
llex_8_3_1_punct1('=', assign).
llex_8_3_1_punct1('?', question).
llex_8_3_1_punct1(':', colon).
llex_8_3_1_punct1('.', dot).
llex_8_3_1_punct1(',', comma).
llex_8_3_1_punct1('@', at).
llex_8_3_1_punct1('(', lparen).
llex_8_3_1_punct1(')', rparen).
llex_8_3_1_punct1('[', lbracket).
llex_8_3_1_punct1(']', rbracket).
llex_8_3_1_punct1('{', lbrace).
llex_8_3_1_punct1('}', rbrace).

    %@spec [LLEX.8.1.2]
    %@spec [LLEX.10.8.5]
    %@spec [LLEX.8.1.3]
:- pred llex_8_1_2_punct(char::in, list(char)::in, token::out, int::out,
              list(char)::out) is semidet.

llex_8_1_2_punct(C, Cs, Tok, Width, Rest) :-
    ( if Cs = [C2 | Cs1], llex_8_1_1_punct2(C, C2, Tok2) then
        Tok = Tok2,
        Width = 2,
        Rest = Cs1
    else
        llex_8_3_1_punct1(C, Tok),
        Width = 1,
        Rest = Cs
    ).

%-----------------------------------------------------------------------------%
% Identifiers
%-----------------------------------------------------------------------------%

    % The start class minus `_`, which has its own arm in `llex_8_2_3_scan_line`.
    %
    %@helper
    %@spec [LLEX.10.1]
    %@spec [LLEX.10.3]
    %@spec [LLEX.10.4]
    %@spec [LLEX.10.5]
:- pred llex_10_4_ascii_id_start(char::in) is semidet.

llex_10_4_ascii_id_start(C) :-
    lnam_2_2_1_id_start(C),
    C \= ('_').


    %@helper
    %@spec [LNAM.2.2.1]
    %@spec [LGRA.2.1.1]
    %@spec [LGRA.2.5.4]
:- pred lnam_2_2_1_ascii_id_cont(char::in) is semidet.

lnam_2_2_1_ascii_id_cont(C) :-
    ( lnam_2_2_1_id_continue(C)
    ; C = ('_')
    ; is_digit(C)
    ).

    %@helper



    % Decides `NAME` against `TYPE_SYM`. Names are NFC from here on: every arm
    % emits the normal form.
    %
    %@spec [LLEX.10.3]
    %@spec [LLEX.10.1]
    %@spec [LLEX.10.3]
    %@spec [LLEX.10.4]
    %@spec [LLEX.10.5]
    %@spec [LLEX.10.5]
    %@spec [LGRA.2.5.1]
    %@spec [LGRA.2.5.2]
    %@spec [LGRA.2.6.19]
    %@spec [LNAM.2.8.1]
:- pred llex_10_4_scan_ident(list(char)::in, lstate::in, scan_step::out) is det.

llex_10_4_scan_ident(Cs, !.St, Result) :-
    take_while_id(Cs, [], RevName, Rest),
    Name = from_char_list(reverse(RevName)),
    Width = length(RevName),
    % NFC first, then validate ([LNAM.2.2.3]). `Width` stays the raw count: the
    % column belongs to the source as written.
    Nfc = lnam_2_4_1_nfc(Name),
    ( if
        Rest = [Next | _],
        char.to_int(Next) > 0x7F,
        not llex_10_2_glyph_start(Next),
        not invisible_control(Next)
    then
        % A non-ASCII character glued to an identifier is part of it, for the
        % diagnostic (`LNAM.2.2_illegal_char_reject`). No DS punctuation is
        % non-ASCII. Bidi and zero-width controls have their own refusals.
        Written = Name ++ from_char(Next),
        Result = scanned(lex_trivia_error(lx_bad_identifier(Written,
            "`" ++ from_char(Next) ++ "` is not an identifier character "
                ++ "([LNAM.2.2])"), here(!.St)))
    else if llex_10_2_has_glyph(Nfc) then
        % Before `lnam_2_2_3_check`, which would call `°C` a bad identifier. The
        % text is folded here and a name's never is: a `type_sym` is no name.
        emit(type_sym(llex_12_2_1_fold_text(Nfc)), Width, Rest, !.St, Result)
    else if lnam_2_2_3_check(Nfc, Reason) then
        ( if llex_10_2_carries_unit_glyph(Nfc) then
            % `kΩ`: a unit glyph in a run that is no legal `NAME` is a `TYPE_SYM`
            % ([LLEX.10.2]). It binds no name: only a type position takes one.
            emit(type_sym(llex_12_2_1_fold_text(Nfc)), Width, Rest, !.St,
                Result)
        else
            Result = scanned(lex_trivia_error(lx_bad_identifier(Nfc, Reason),
                here(!.St)))
        )
    else
        emit(name(Nfc), Width, Rest, !.St, Result)
    ).

    % One walk for both token classes: `mΩ` cannot be classed from its first
    % character.
    %
    %@helper
:- pred take_while_id(list(char)::in, list(char)::in, list(char)::out,
                      list(char)::out) is det.

take_while_id([], Acc, Acc, []).
take_while_id([C | Cs], Acc, Out, Rest) :-
    ( if
        ( lnam_2_2_1_ascii_id_cont(C)
        ; llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C))
        )
    then
        take_while_id(Cs, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

%-----------------------------------------------------------------------------%
% TYPE_SYM -- [LLEX.10.2]
%-----------------------------------------------------------------------------%
%
% [LLEX.12.2]'s seven characters and their four confusables, against the
% vendored UCD:
%
%   NOT XID AT ALL          ° U+00B0, ′ U+2032, ″ U+2033
%   XID BUT NOT `Allowed`   µ U+00B5, ₙ U+2099, Ω U+2126, ʹ U+02B9,
%                           ʺ U+02BA, Å U+212B
%   XID AND `Allowed`       Ω U+03A9, Å U+00C5, μ U+03BC
%
% The legal identifier set is XID ∩ Allowed. A run carrying only the third group
% and legal as a name is a `name`, which `take_type` also accepts.

    % On the NFC form: NFC maps OHM SIGN and ANGSTROM SIGN to legal identifier
    % characters, so a run spelt with them can come back a `name`.
    %
    %@spec [LLEX.10.2]
    %@spec [LGRA.2.5.3]
:- pred llex_10_2_has_glyph(string::in) is semidet.

llex_10_2_has_glyph(S) :-
    % Every glyph is past ASCII, and this runs on every name.
    not all_ascii(S),
    some [C] (
        member(C, to_char_list(S)),
        llex_10_2_glyph_only(C)
    ).

    % Any unit glyph after the fold, the identifier-legal ones included. Asked
    % only of a run refused as a name.
    %
    %@spec [LLEX.10.2]
:- pred llex_10_2_carries_unit_glyph(string::in) is semidet.

llex_10_2_carries_unit_glyph(S) :-
    some [C] (
        member(C, to_char_list(S)),
        llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C))
    ).

    % A unit glyph that cannot also be an identifier character.
    %
    %@spec [LLEX.10.2]
    %@spec [LNAM.2.2.4]
:- pred llex_10_2_glyph_only(char::in) is semidet.

llex_10_2_glyph_only(C) :-
    llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C)),
    not lnam_2_2_1_id_continue(C).

    % `ₙ` is continuation-only: `take_while_id` admits it inside a run.
    %
    %@spec [LLEX.10.2]
:- pred llex_10_2_glyph_start(char::in) is semidet.

llex_10_2_glyph_start(C) :-
    llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C)),
    llex_12_2_1_fold_confusable(C) \= subscript_n.

    %@spec [LLEX.12.2.1]
:- func llex_12_2_1_fold_text(string) = string.

llex_12_2_1_fold_text(S) =
    from_char_list(map(llex_12_2_1_fold_confusable, to_char_list(S))).

    %@helper
:- pred non_ascii(char::in) is semidet.

non_ascii(C) :- char.to_int(C) > 127.

%-----------------------------------------------------------------------------%
% Numbers -- [LLEX.11.3.1]'s ladder
%-----------------------------------------------------------------------------%

    % The ladder: scientific float, unit literal, dotted float, integer, each
    % arm below. `e` with digits after it is withheld from `UNIT_SUFFIX`, which is
    % the only way `1e6` is a float. Any other letter after a digit is a unit:
    % `30x` is an unknown unit later, never `30 * x`.
    %
    %@spec [LLEX.11.1]
    %@spec [LLEX.11.2]
    %@spec [LLEX.11.2.1]
    %@spec [LLEX.11.2.2]
    %@spec [LLEX.11.2.3]
    %@spec [LLEX.11.3.1]
    %@spec [LLEX.12.1]
    %@spec [LLEX.12.1.1]
    %@spec [LUNI.3.1.4]
    %@spec [LUNI.3.1.8]
    %@spec [LGRA.2.7.5]
:- pred llex_11_3_1_scan_number(list(char)::in, lstate::in, scan_step::out) is det.

llex_11_3_1_scan_number(Cs, !.St, Result) :-
    ( if Cs = ['0', P | AfterPrefix], llex_11_1_base_prefix(P, Base) then
        ( if AfterPrefix = ['_' | _] then
            Result = scanned(lex_trivia_error(
                lx_underscore_placement("0" ++ from_char(P) ++ "_"), here(!.St)))
        else
            take_base_digits(AfterPrefix, Base, [], RevD, Rest1),
            ( if RevD = [] then
                Result = scanned(lex_trivia_error(
                    lx_bad_numeric_suffix("0" ++ from_char(P), ""), here(!.St)))
            else
                DText = from_char_list(reverse(RevD)),
                Text = "0" ++ from_char(P) ++ DText,
                Width = 2 + length(RevD),
                ( if Rest1 = [U | AfterU], llex_12_2_unit_suffix_start(U) then
                    ( if
                        U = ('_'),
                        not (
                            AfterU = [V | _],
                            V \= ('_'),
                            llex_12_2_unit_suffix_start(V)
                        )
                    then
                        % `0xFF_` or `0x1__F`.
                        Result = scanned(lex_trivia_error(
                            lx_underscore_placement(Text ++ "_"), here(!.St)))
                    else
                        % `0xff_s`: adjacency commits to a unit, so it is refused
                        % as one, not split into an integer and a name.
                        Result = scanned(lex_trivia_error(lx_based_unit(Text),
                            here(!.St)))
                    )
                else
                    llex_11_1_5_finish_number(Text, base_of(Base), strip_seps(DText),
                        Width, Rest1, !.St, Result)
                )
            )
        )
    else
        take_numeric(Cs, [], RevNum, Rest0),
        NumText = from_char_list(reverse(RevNum)),
        NumWidth = length(RevNum),
        ( if suffix(NumText, "_") then
            Result = scanned(lex_trivia_error(lx_underscore_placement(NumText),
                here(!.St)))
        else if Rest0 = ['.' | AfterDot], not starts_digit(AfterDot) then
            Result = scanned(lex_trivia_error(lx_bare_fraction, here(!.St)))
        else if
            Rest0 = [E | AfterE],
            ( E = 'e' ; E = 'E' ),
            exponent_digits(AfterE, RevExp, Rest1),
            RevExp = [_ | _]
        then
            ( if AfterE = ['_' | _] then
                Result = scanned(lex_trivia_error(
                    lx_underscore_placement(NumText ++ "e_"), here(!.St)))
            else
                ExpText = from_char_list(reverse(RevExp)),
                Text = NumText ++ from_char(E) ++ ExpText,
                Width = NumWidth + 1 + length(RevExp),
                ( if Rest1 = [U | _], llex_12_2_unit_suffix_start(U) then
                    % `1e6s` and `1.0e3_ms` are unit literals.
                    scan_unit_suffix(Rest1, Text, Width, !.St, Result)
                else
                    finish_float(Text, Width, Rest1, !.St, Result)
                )
            )
        else if Rest0 = [U | _], llex_12_2_unit_suffix_start(U) then
            scan_unit_suffix(Rest0, NumText, NumWidth, !.St, Result)
        else if contains_char(NumText, '.') then
            finish_float(NumText, NumWidth, Rest0, !.St, Result)
        else
            llex_11_1_5_finish_number(NumText, 10, strip_seps(NumText), NumWidth, Rest0,
                !.St, Result)
        )
    ).

    % Lowercase only: `0B` is a byte quantity, a `0` and a unit.
    %
    %@spec [LLEX.11.1]
:- pred llex_11_1_base_prefix(char::in, num_base::out) is semidet.

llex_11_1_base_prefix('x', hex).
llex_11_1_base_prefix('b', bin).
llex_11_1_base_prefix('o', oct).

    %@helper
:- type num_base ---> hex ; bin ; oct.

    %@helper
:- func base_of(num_base) = int.

base_of(hex) = 16.
base_of(bin) = 2.
base_of(oct) = 8.

    %@helper
:- pred base_digit(num_base::in, char::in) is semidet.

base_digit(hex, C) :- is_hex_digit(C).
base_digit(bin, C) :- ( C = '0' ; C = '1' ).
base_digit(oct, C) :- is_digit(C), C @< '8'.

    %@helper
:- pred take_base_digits(list(char)::in, num_base::in, list(char)::in,
                         list(char)::out, list(char)::out) is det.

take_base_digits([], _, Acc, Acc, []).
take_base_digits([C | Cs], Base, Acc, Out, Rest) :-
    ( if base_digit(Base, C) then
        take_base_digits(Cs, Base, [C | Acc], Out, Rest)
    else if C = ('_'), Cs = [D | _], base_digit(Base, D) then
        % The separator is kept for the token's width; `strip_seps` removes it.
        take_base_digits(Cs, Base, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

    %@spec [LLEX.11.1.5]
    %@spec [LGRA.2.7.3]
:- pred llex_11_1_5_finish_number(string::in, int::in, string::in, int::in,
                      list(char)::in, lstate::in, scan_step::out) is det.

llex_11_1_5_finish_number(Text, Base, Digits, Width, Rest, !.St, Result) :-
    ( if i64.from_base_digits(Base, Digits, I) then
        emit(int_lit(I), Width, Rest, !.St, Result)
    else if Base = 10, Digits = "9223372036854775808" then
        % 2^63 goes to the parser, which folds `-` over it to INT64_MIN and
        % refuses it anywhere else.
        emit(int_min_magnitude, Width, Rest, !.St, Result)
    else
        Result = scanned(lex_trivia_error(lx_int_out_of_range(Text),
            here(!.St)))
    ).

    % The value is `ds.float_text`'s, libds's parser, not the host's `strtod`.
    %
    %@helper
:- pred finish_float(string::in, int::in, list(char)::in, lstate::in,
                     scan_step::out) is det.

finish_float(Text, Width, Rest, !.St, Result) :-
    ( if dsc.exact.llex_11_2_4_past_largest(strip_seps(Text)) then
        Result = scanned(lex_trivia_error(lx_float_out_of_range(Text),
            here(!.St)))
    else if float_text.parse_json(json_number(strip_seps(Text)), F) then
        ( if float.is_infinite(F) then
            Result = scanned(lex_trivia_error(lx_float_out_of_range(Text),
                here(!.St)))
        else
            emit(float_lit(F), Width, Rest, !.St, Result)
        )
    else
        Result = scanned(lex_trivia_error(lx_bad_numeric_suffix(Text, ""),
            here(!.St)))
    ).

    % A FLOAT_LIT's digits as an RFC 8259 number: the integer part's leading
    % zeros dropped, one kept before a `.`, an exponent or the end.
    %
    %@helper
:- func json_number(string) = string.

json_number(S) = string.from_char_list(drop_zeros(string.to_char_list(S))).

    %@helper
:- func drop_zeros(list(char)) = list(char).

drop_zeros(Cs) =
    ( if Cs = ['0', Next | Rest], char.is_digit(Next) then
        drop_zeros([Next | Rest])
    else
        Cs
    ).

    %@helper
:- pred starts_digit(list(char)::in) is semidet.

starts_digit([C | _]) :- is_digit(C).

    %@spec [LLEX.12.2]
:- pred llex_12_2_unit_suffix_start(char::in) is semidet.

llex_12_2_unit_suffix_start(C) :-
    ( llex_10_4_ascii_id_start(C)
    ; C = ('_')
    ; llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C)),
      llex_12_2_1_fold_confusable(C) \= subscript_n
    ).

    %@spec [LLEX.12.2]
:- pred llex_12_2_unit_glyph(char::in) is semidet.

llex_12_2_unit_glyph('\xB0\').     % DEGREE SIGN
llex_12_2_unit_glyph('\x2032\').   % PRIME
llex_12_2_unit_glyph('\x2033\').   % DOUBLE PRIME
llex_12_2_unit_glyph('\x3A9\').    % GREEK CAPITAL LETTER OMEGA
llex_12_2_unit_glyph('\xB5\').     % MICRO SIGN
llex_12_2_unit_glyph('\xC5\').     % LATIN CAPITAL LETTER A WITH RING ABOVE
llex_12_2_unit_glyph(subscript_n).

    %@helper
:- func subscript_n = char.

subscript_n = '\x2099\'.  % LATIN SUBSCRIPT SMALL LETTER N, for `g\x2099\`

    %@spec [LLEX.12.2.1]
:- func llex_12_2_1_fold_confusable(char) = char.

llex_12_2_1_fold_confusable(C) =
    ( if C = '\x3BC\' then '\xB5\'        % GREEK SMALL MU -> MICRO SIGN
    else if C = '\x2126\' then '\x3A9\'   % OHM SIGN -> GREEK CAPITAL OMEGA
    else if C = '\x2B9\' then '\x2032\'   % MODIFIER PRIME -> PRIME
    else if C = '\x2BA\' then '\x2033\'   % MODIFIER DOUBLE -> DOUBLE PRIME
    else C
    ).

    %@helper
:- pred scan_unit_suffix(list(char)::in, string::in, int::in, lstate::in,
                         scan_step::out) is det.

scan_unit_suffix(Cs, NumText, NumWidth, !.St, Result) :-
    llex_12_3_take_unit_suffix(Cs, [], RevSuf, Rest),
    ( if
        Cs = ['_' | AfterSep],
        not (
            AfterSep = [V | _],
            V \= ('_'),
            llex_12_2_unit_suffix_start(V)
        )
    then
        % `42_`, `1__2`, `5__s`: a separator only before a unit start.
        Result = scanned(lex_trivia_error(
            lx_underscore_placement(NumText ++ "_"), here(!.St)))
    else if RevSuf = [] then
        Result = scanned(lex_trivia_error(lx_bad_numeric_suffix(NumText, ""),
            here(!.St)))
    else if RevSuf = [C], ( C = 'i' ; C = 'j' ) then
        Result = scanned(lex_trivia_error(
            lx_complex_literal(NumText ++ from_char(C)), here(!.St)))
    else if luni_3_1_5_bare_imaginary(RevSuf) then
        Result = scanned(lex_trivia_error(
            lx_bare_imaginary(NumText ++ from_char_list(reverse(RevSuf))),
            here(!.St)))
    else if Rest = [Bad | _], stray_non_ascii(Bad) then
        Result = scanned(lex_trivia_error(lx_bad_unit_char(Bad), here(!.St)))
    else if dsc.exact.llex_11_2_4_past_largest(strip_seps(NumText)) then
        Result = scanned(lex_trivia_error(lx_float_out_of_range(NumText),
            here(!.St)))
    else
        Suffix = from_char_list(
            list.map(llex_12_2_1_fold_confusable, reverse(RevSuf))),
        emit(unit_lit(NumText, Suffix), NumWidth + length(RevSuf), Rest,
            !.St, Result)
    ).

    %@helper
:- pred stray_non_ascii(char::in) is semidet.

stray_non_ascii(C) :-
    non_ascii(C),
    not llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C)).

    % Stops before a `_` no digit follows: `23_000_m` is 23000, the unit `_`, `m`.
    %
    %@helper
:- pred take_numeric(list(char)::in, list(char)::in, list(char)::out,
                     list(char)::out) is det.

take_numeric([], Acc, Acc, []).
take_numeric([C | Cs], Acc, Out, Rest) :-
    ( if is_digit(C) then
        take_numeric(Cs, [C | Acc], Out, Rest)
    else if C = ('.'), Cs = [D | _], is_digit(D) then
        take_numeric(Cs, [C | Acc], Out, Rest)
    else if C = ('_'), Cs = [D | _], is_digit(D) then
        take_numeric(Cs, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

    % The argument is reversed, so `_i` arrives as `['i', '_']`.
    %
    %@spec [LUNI.3.1.5]
:- pred luni_3_1_5_bare_imaginary(list(char)::in) is semidet.

luni_3_1_5_bare_imaginary(RevSuf) :-
    ( RevSuf = [C] ; RevSuf = [C, '_'] ),
    ( C = 'i' ; C = 'j' ).

    %@spec [LLEX.12.3]
    %@spec [LLEX.12.5]
    %@spec [LUNI.3.1.1]
:- pred llex_12_3_take_unit_suffix(list(char)::in, list(char)::in, list(char)::out,
                         list(char)::out) is det.

llex_12_3_take_unit_suffix([], Acc, Acc, []).
llex_12_3_take_unit_suffix([C | Cs], Acc, Out, Rest) :-
    ( if lnam_2_2_1_ascii_id_cont(C) ; llex_12_2_unit_glyph(llex_12_2_1_fold_confusable(C)) then
        llex_12_3_take_unit_suffix(Cs, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

    %@helper
:- pred exponent_digits(list(char)::in, list(char)::out, list(char)::out)
    is det.

exponent_digits(Cs0, RevExp, Rest) :-
    ( if Cs0 = [S | Cs1], ( S = ('+') ; S = ('-') ) then
        take_exponent_digits(Cs1, [S], RevExp, Rest)
    else
        take_exponent_digits(Cs0, [], RevExp, Rest)
    ).

    % A `_` with no digit after it ends the exponent: it may begin a unit suffix.
    %
    %@helper
:- pred take_exponent_digits(list(char)::in, list(char)::in, list(char)::out,
                             list(char)::out) is det.

take_exponent_digits([], Acc, Acc, []).
take_exponent_digits([C | Cs], Acc, Out, Rest) :-
    ( if is_digit(C) then
        take_exponent_digits(Cs, [C | Acc], Out, Rest)
    else if
        C = ('_'),
        Acc = [Prev | _],
        is_digit(Prev),
        Cs = [D | _],
        is_digit(D)
    then
        take_exponent_digits(Cs, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

    %@helper
:- pred take_digits(list(char)::in, list(char)::in, list(char)::out,
                    list(char)::out) is det.

take_digits([], Acc, Acc, []).
take_digits([C | Cs], Acc, Out, Rest) :-
    ( if is_digit(C) then
        take_digits(Cs, [C | Acc], Out, Rest)
    else
        Out = Acc,
        Rest = [C | Cs]
    ).

    %@helper
:- func strip_seps(string) = string.

strip_seps(S) = replace_all(S, "_", "").

%-----------------------------------------------------------------------------%
% Strings
%-----------------------------------------------------------------------------%

    %@spec [LLEX.8.3.3]
    %@spec [LNAM.2.4.2]
    %@spec [LGRA.2.9.1]
    %@spec [LGRA.2.9.5]
    %@spec [LGRA.2.9.7]
:- pred llex_8_3_3_scan_string(list(char)::in, lstate::in, scan_step::out) is det.

llex_8_3_3_scan_string(Cs, !.St, Result) :-
    ( if Cs = ['"', '"' | Body] then
        llex_6_7_1_take_triple(Body, [], !.St ^ lx_line, !.St ^ lx_col + 3, Res),
        (
            Res = tr_ok(Text, EndLine, EndCol, Rest),
            string_bidi_check(Text, !.St ^ lx_line, !.St ^ lx_col + 3, Bidi),
            (
                Bidi = yes(Err),
                Result = scanned(Err)
            ;
                Bidi = no,
                P = here(!.St),
                % The one token whose span crosses lines.
                !St ^ lx_cur :=
                    [positioned(triple_str(Text), P, pos(EndLine, EndCol))
                        | !.St ^ lx_cur],
                !St ^ lx_line := EndLine,
                !St ^ lx_col := EndCol,
                Result = in_line(Rest, !.St)
            )
        ;
            Res = tr_unterminated,
            Result = scanned(lex_trivia_error(lx_unterminated_triple,
                here(!.St)))
        )
    else
        lgra_2_9_2_take_single(Cs, [], SRes),
        (
            SRes = ss_ok(Text, Rest, Width),
            string_bidi_check(Text, !.St ^ lx_line, !.St ^ lx_col + 1, Bidi),
            (
                Bidi = yes(Err),
                Result = scanned(Err)
            ;
                Bidi = no,
                emit(single_str(Text), Width + 2, Rest, !.St, Result)
            )
        ;
            SRes = ss_unterminated,
            Result = scanned(lex_trivia_error(lx_unterminated_string,
                here(!.St)))
        )
    ).

    %@helper
:- type single_result
    --->    ss_ok(string, list(char), int)
    ;       ss_unterminated.

    %@spec [LGRA.2.9.2]
:- pred lgra_2_9_2_take_single(list(char)::in, list(char)::in, single_result::out) is det.

lgra_2_9_2_take_single([], _, ss_unterminated).
lgra_2_9_2_take_single([C | Cs], Acc, Result) :-
    ( if C = '"' then
        Result = ss_ok(from_char_list(reverse(Acc)), Cs, length(Acc))
    else if C = '\n' then
        Result = ss_unterminated
    else if C = ('\\'), Cs = [E | Cs1] then
        % Both kept: a `\"` here must not end the literal.
        lgra_2_9_2_take_single(Cs1, [E, C | Acc], Result)
    else
        lgra_2_9_2_take_single(Cs, [C | Acc], Result)
    ).

    %@helper
:- type triple_result
    --->    tr_ok(string, int, int, list(char))
    ;       tr_unterminated.

    % A backslash takes the character after it, so `\"` cannot begin the close.
    %
    %@spec [LLEX.6.7.1]
    %@spec [LGRA.2.9.3]
    %@spec [LGRA.2.9.1]
:- pred llex_6_7_1_take_triple(list(char)::in, list(char)::in, int::in, int::in,
                    triple_result::out) is det.

llex_6_7_1_take_triple([], _, _, _, tr_unterminated).
llex_6_7_1_take_triple([C | Cs], Acc, Line, Col, Result) :-
    ( if C = '"', Cs = ['"', '"' | Rest] then
        Result = tr_ok(from_char_list(reverse(Acc)), Line, Col + 3, Rest)
    else if C = '\n' then
        llex_6_7_1_take_triple(Cs, [C | Acc], Line + 1, 0, Result)
    else if C = ('\\'), Cs = [E | Cs1] then
        ( if E = '\n' then
            llex_6_7_1_take_triple(Cs1, [E, C | Acc], Line + 1, 0, Result)
        else
            llex_6_7_1_take_triple(Cs1, [E, C | Acc], Line, Col + 2, Result)
        )
    else
        llex_6_7_1_take_triple(Cs, [C | Acc], Line, Col + 1, Result)
    ).

%-----------------------------------------------------------------------------%

describe_lex_error(lx_ill_formed_utf8) =
    "the source is not well-formed UTF-8 here; DS source files are UTF-8 "
        ++ "([LLEX.1.1])".
describe_lex_error(lx_lone_bang) =
    "`!` is not a token on its own; write `!=` or `!~`".
describe_lex_error(lx_ellipsis) =
    "ellipsis not valid in DS".
describe_lex_error(lx_bad_char(C)) =
    "unexpected character `" ++ from_char(C) ++ "`".
describe_lex_error(lx_lone_cr) =
    "a carriage return with no line feed after it; line endings are LF or "
        ++ "CRLF ([LLEX.2.2])".
describe_lex_error(lx_unterminated_string) =
    "unterminated string literal".
describe_lex_error(lx_unterminated_triple) =
    "unterminated triple-quoted string".
describe_lex_error(lx_bad_numeric_suffix(Num, Suf)) =
    "`" ++ Num ++ Suf ++ "` is neither a unit literal nor a number".
describe_lex_error(lx_leading_underscore) =
    "an identifier cannot start with a single `_`".
describe_lex_error(lx_bidi_unterminated(Where, C)) =
    "unterminated bidi control " ++ bidi_control_name(C) ++ " in "
        ++ bidi_where_text(Where) ++ ": it is never closed, so its reordering "
        ++ "escapes into the surrounding source and displayed code can differ "
        ++ "from compiled code ([LNAM.2.6.3])".
describe_lex_error(lx_bidi_unmatched(Where, C)) =
    "unbalanced bidi control " ++ bidi_control_name(C) ++ " in "
        ++ bidi_where_text(Where) ++ ": it closes nothing ([LNAM.2.6.3])".

    %@helper
:- func bidi_where_text(bidi_where) = string.

bidi_where_text(bw_string) = "a string literal".
bidi_where_text(bw_comment) = "a comment".
describe_lex_error(lx_unterminated_regex) =
    "unterminated regex literal: the pattern after `~` / `!~` must close with "
        ++ "`/` on the same line; write `\\n` for a newline ([LREG.6.5])".
describe_lex_error(lx_bare_fraction) =
    "both sides of the decimal point are required".
describe_lex_error(lx_underscore_placement(S)) =
    "misplaced `_` in the numeric literal `" ++ S ++ "`".
describe_lex_error(lx_int_out_of_range(S)) =
    "integer literal out of range: `" ++ S ++ "`".
describe_lex_error(lx_float_out_of_range(S)) =
    "float literal out of range: `" ++ S ++ "` is past the largest finite "
        ++ "Float; an infinity is written `inf` ([LLEX.11.2.4])".
describe_lex_error(lx_based_unit(S)) =
    "`" ++ S ++ "` cannot carry a unit: a unit literal's numeric prefix is "
        ++ "decimal, because `_` is also a digit separator in hex and a unit "
        ++ "may be spelled in hex digits -- `0xFF_A` is 4090, not 255 amperes "
        ++ "([LUNI.3.1.8])".
describe_lex_error(lx_bare_imaginary(S)) =
    "`" ++ S ++ "`: a bare `i` or `j` suffix is not a token class in v1 -- "
        ++ "the `complex` type is specified but unbuilt ([LUNI.14]), so "
        ++ "[LUNI.3.1.5] withholds `i`/`j` from a unit suffix".
describe_lex_error(lx_complex_literal(S)) =
    "`" ++ S ++ "`: complex numbers are not in this edition of DS "
        ++ "([LUNI.14.9])".
describe_lex_error(lx_bad_unit_char(C)) =
    "`" ++ from_char(C) ++ "` is not a permitted unit-symbol character".
describe_lex_error(lx_bad_identifier(Name, Reason)) =
    "`" ++ Name ++ "`: " ++ Reason.

%-----------------------------------------------------------------------------%
:- end_module dsc.lex.
%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% test_dsc -- unit tests for the DS compiler's front end, and the driver that
% runs every suite in this directory.
%-----------------------------------------------------------------------------%

% @spec [LADP.8.5.4]
:- module test_dsc.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.
:- import_module ds.capability.
:- import_module ds.json.
:- import_module ds.re2.

:- import_module dsc.
:- import_module dsc.ast.
:- import_module dsc.astjson.
:- import_module dsc.capability.
:- import_module dsc.driver.
:- import_module dsc.build.
:- import_module dsc.builtin_types.
:- import_module dsc.cast.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.dialect.
:- import_module dsc.exact.
:- import_module dsc.json.
:- import_module dsc.layout.
:- import_module dsc.cst.
:- import_module dsc.expr.
:- import_module dsc.imports.
:- import_module dsc.lex.
:- import_module dsc.narrow.
:- import_module dsc.parse.
:- import_module dsc.render.
:- import_module dsc.resolve.
:- import_module dsc.series.
:- import_module dsc.strlit.
:- import_module dsc.token.
:- import_module dsc.typecheck.
:- import_module dsc.types.
:- import_module dsc.validate.
:- import_module dsc.uniname.
:- import_module dsc.yaml.

:- import_module test_behave.
:- import_module test_cli.
:- import_module test_conformance.
:- import_module test_dstest.
:- import_module test_encode.
:- import_module test_lower.
:- import_module test_registry.

:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module integer.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module string.

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

main(!IO) :-
    some [!T] (
    !:T = tally(0, 0),
    test_layout(!T, !IO),
    test_lex(!T, !IO),
    test_lex_trivia(!T, !IO),
    test_dump_ast(!T, !IO),
    test_strlit(!T, !IO),
    test_rule(!T, !IO),
    test_render(!T, !IO),
    test_re2(!T, !IO),
    test_regex(!T, !IO),
    test_intervals(!T, !IO),
    test_let_order(!T, !IO),
    test_interp_specs(!T, !IO),
    test_consts(!T, !IO),
    test_response_fields(!T, !IO),
    test_unit_decls(!T, !IO),
    test_exact(!T, !IO),
    test_currency(!T, !IO),
    test_opaque(!T, !IO),
    test_string_methods(!T, !IO),
    test_members(!T, !IO),
    test_literal_refusals(!T, !IO),
    test_series_and_call_refusals(!T, !IO),
    test_series_declarations(!T, !IO),
    test_window_read(!T, !IO),
    test_wrong_code_second(!T, !IO),
    test_warnings(!T, !IO),
    test_nolinscan_refusals(!T, !IO),
    test_nolinscan_anchors(!T, !IO),
    test_sibling_responses(!T, !IO),
    test_call_kwarg_values(!T, !IO),
    test_then_followers(!T, !IO),
    test_as_keys(!T, !IO),
    test_expr(!T, !IO),
    test_rhs(!T, !IO),
    test_decls(!T, !IO),
    test_diag(!T, !IO),
    test_build(!T, !IO),
    test_import(!T, !IO),
    test_unit(!T, !IO),
    test_resolve(!T, !IO),
    test_cast(!T, !IO),
    test_dim(!T, !IO),
    test_narrow(!T, !IO),
    test_typecheck(!T, !IO),
    test_validate(!T, !IO),
    test_dialect_files(!T, !IO),
    test_companion(!T, !IO),
    test_type_sym(!T, !IO),
    test_bidi(!T, !IO),
    test_parse(!T, !IO),
    test_uniname(!T, !IO),
    test_json(!T, !IO),
    test_nfc_conformance(!T, !IO),
    test_encode.run(EncPass, EncFail, !IO),
    test_conformance.run(ConfPass, ConfFail, !IO),
    test_lower.run(LowPass, LowFail, !IO),
    test_behave.run(BehPass, BehFail, !IO),
    test_dstest.run(TstPass, TstFail, !IO),
    test_registry.run(RegPass, RegFail, !IO),
    test_cli.run(CliPass, CliFail, !IO),
    T = tally(!.T ^ t_pass + EncPass + ConfPass + LowPass + BehPass + TstPass
                  + RegPass + CliPass,
              !.T ^ t_fail + EncFail + ConfFail + LowFail + BehFail + TstFail
                  + RegFail + CliFail),
    io.format("test_dsc: %d passed, %d failed\n",
        [i(T ^ t_pass), i(T ^ t_fail)], !IO),
    ( if T ^ t_fail > 0 then
        io.set_exit_status(1, !IO)
    else
        true
    )
    ).

%-----------------------------------------------------------------------------%
% Fixtures
%-----------------------------------------------------------------------------%

    % A line at `Indent` carrying `Names` as bare `name` tokens. The column is
    % the indent, which is what the lexer would report.
    %
:- func line(int, list(string)) = source_line.

line(Indent, Names) =
    source_line(Indent, positions(Indent, map(func(N) = name(N), Names))).

    % A line whose tokens are given explicitly, for the bracket cases.
    %
:- func toks_line(int, list(token)) = source_line.

toks_line(Indent, Toks) = source_line(Indent, positions(Indent, Toks)).

:- func positions(int, list(token)) = list(positioned).

positions(Col0, Toks) = Ps :-
    % One column per token; the layout pass never reads the extent.
    list.map_foldl(
        ( pred(Tok::in, positioned(Tok, pos(1, C), pos(1, C + 1))::out,
               C::in, C + 1::out) is det ),
        Toks, Ps, Col0, _).

    % The layout tokens only.
    %
:- func shape(list(positioned)) = list(token).

shape(Ps) = filter(layout_token, map(func(P) = P ^ tk_tok, Ps)).

    % Assert the layout SHAPE of a token stream.
    %
:- pred check_shape(string::in, list(source_line)::in, list(token)::in,
                    tally::in, tally::out, io::di, io::uo) is det.

check_shape(Name, Lines, Want, !T, !IO) :-
    llex_6_2_layout(Lines, Result),
    ( if Result = lay_ok(Toks), shape(Toks) = Want then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % Assert the error, ignoring its position.
    %
:- pred check_error(string::in, list(source_line)::in, layout_error::in,
                    tally::in, tally::out, io::di, io::uo) is det.

check_error(Name, Lines, Want, !T, !IO) :-
    llex_6_2_layout(Lines, Result),
    ( if Result = lay_error(Want, _) then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% The layout pass
%-----------------------------------------------------------------------------%

:- pred test_layout(tally::in, tally::out, io::di, io::uo) is det.

test_layout(!T, !IO) :-
    % One flat line: NEWLINE and nothing else. The stack never leaves 0, so
    % [LLEX.6.5] has nothing to flush.
    check_shape("flat line is one newline",
        [line(0, ["schema"])], [newline], !T, !IO),

    % [LLEX.6.3]: a rise of 4 pushes one level; [LLEX.6.5] flushes it.
    % [LLEX.7.4]: INDENT comes before the new line's first token, after the
    % previous NEWLINE.
    check_shape("[LLEX.7.4] indent follows the newline, before the line",
        [line(0, ["schema"]), line(4, ["slot"])],
        [newline, indent, newline, dedent], !T, !IO),

    % A rise of 8 is two levels and two INDENTs [LLEX.6.3].
    check_shape("rise of 8 is two indents",
        [line(0, ["a"]), line(8, ["b"])],
        [newline, indent, indent, newline, dedent, dedent], !T, !IO),

    % Falling two levels at once emits two DEDENTs, then the stack matches.
    check_shape("fall of 8 is two dedents",
        [line(0, ["a"]), line(8, ["b"]), line(0, ["c"])],
        [newline, indent, indent, newline, dedent, dedent, newline],
        !T, !IO),

    % Equal indent emits nothing at all [LLEX.6.3].
    check_shape("equal indent emits nothing",
        [line(0, ["a"]), line(0, ["b"])], [newline, newline], !T, !IO),

    % Inside an open group NEWLINE is suppressed ([LLEX.7.3]) and the 4-space
    % rule does not apply ([LLEX.6.4], [LLEX.7.5.5]), so a continuation at
    % column 7 is legal and contributes no layout token.
    check_shape("brackets suspend newline AND indentation",
        [ toks_line(0, [name("call"), lparen])
        , toks_line(7, [name("body")])
        , toks_line(0, [rparen])
        ],
        [newline], !T, !IO),

    % The same column 7 outside a group is [LLEX.6.4]'s error.
    check_error("[LLEX.6.4] rise of 7 is inconsistent indentation",
        [line(0, ["a"]), line(7, ["b"])],
        le_inconsistent_indent(7, 0), !T, !IO),

    % [LLEX.6.3]: a fall to a column matching no enclosing block is the
    % dedent error, not the indentation error.
    check_error("[LLEX.6.3] fall to column 6 matches no block",
        [line(0, ["a"]), line(4, ["b"]), line(8, ["c"]), line(6, ["d"])],
        le_inconsistent_dedent(6), !T, !IO),

    % [LLEX.7.5.3]: the state is a stack of expected closers.
    check_error("[LLEX.7.5.3] mismatched closer",
        [toks_line(0, [name("a"), lparen, rbracket])],
        le_mismatched_closer(rbracket, rparen), !T, !IO),

    check_error("unmatched closer with no open group",
        [toks_line(0, [rparen])], le_unexpected_closer(rparen), !T, !IO),

    check_error("unclosed bracket at EOF",
        [toks_line(0, [name("a"), lparen])],
        le_unclosed_bracket(rparen), !T, !IO),

    % A layout token from the lexer is refused.
    check_error("a layout token from the lexer is refused",
        [toks_line(0, [name("a"), newline])],
        le_layout_token_from_lexer(newline), !T, !IO).

%-----------------------------------------------------------------------------%
% The lexer
%-----------------------------------------------------------------------------%

    % The flat token stream, lines concatenated.
    %
:- pred check_toks(string::in, string::in, list(token)::in,
                   tally::in, tally::out, io::di, io::uo) is det.

check_toks(Name, Src, Want, !T, !IO) :-
    llex_5_4_lex(Src, Result),
    ( if
        Result = lex_ok(Lines),
        condense(map(func(L) = map(func(P) = P ^ tk_tok, L ^ sl_tokens),
            Lines)) = Want
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred check_lex_error(string::in, string::in, lex_error::in,
                        tally::in, tally::out, io::di, io::uo) is det.

check_lex_error(Name, Src, Want, !T, !IO) :-
    llex_5_4_lex(Src, Result),
    ( if Result = lex_error(Want, _) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

    % How many lines survived ([LLEX.5.2]).
    %
:- pred check_lines(string::in, string::in, int::in,
                    tally::in, tally::out, io::di, io::uo) is det.

check_lines(Name, Src, Want, !T, !IO) :-
    llex_5_4_lex(Src, Result),
    ( if Result = lex_ok(Lines), length(Lines) = Want then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% The lexer's side channel -- comments and blank lines, for `ds_ast`
%-----------------------------------------------------------------------------%
%

:- pred check_trivia(string::in, string::in, list(comment)::in,
                     list(blank_run)::in,
                     tally::in, tally::out, io::di, io::uo) is det.

check_trivia(Name, Src, Comments, Runs, !T, !IO) :-
    llex_5_4_lex_trivia(Src, Result),
    ( if Result = lex_trivia_ok(_, trivia(Comments, Runs)) then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_lex_trivia(tally::in, tally::out, io::di, io::uo) is det.

test_lex_trivia(!T, !IO) :-
    % Both entry points hand back the same lines.
    Busy = "# head\nschema S:  # after\n\n    a: Int\n\n\n# own\nrule r:\n",
    check("the side channel leaves the lines alone",
        ( if
            llex_5_4_lex(Busy, lex_ok(Lines)),
            llex_5_4_lex_trivia(Busy, lex_trivia_ok(Lines, _))
        then yes else no ), !T, !IO),
    check_trivia("an own-line and a trailing comment, with their columns",
        "schema S:\n    a: Int  # trailing\n# own\n",
        [comment("# trailing", pos(2, 12), cp_trailing),
         comment("# own", pos(3, 0), cp_own_line)], [], !T, !IO),
    check_trivia("a `##` banner keeps every `#`",
        "## banner ##\n", [comment("## banner ##", pos(1, 0), cp_own_line)],
        [], !T, !IO),
    check_trivia("a CRLF line's `\\r` is not comment text",
        "a # x\r\nb\r\n", [comment("# x", pos(1, 2), cp_trailing)], [],
        !T, !IO),
    check_trivia("a `#` inside a string is not a comment",
        "a = \"x # y\"\n", [], [], !T, !IO),
    check_trivia("a blank run is filed against the line after it",
        "a\n\n\nb\n", [], [blank_run(4, 2)], !T, !IO),
    % A comment-only line has no tokens ([LLEX.5.2]) but ends a blank run.
    check_trivia("a comment line splits two blank runs",
        "a\n\n# c\n\nb\n", [comment("# c", pos(3, 0), cp_own_line)],
        [blank_run(3, 1), blank_run(5, 1)], !T, !IO),
    check_trivia("blank lines at the end of file",
        "a\n\n", [], [blank_run(3, 1)], !T, !IO),
    check_trivia("a blank line inside a docstring is the docstring's",
        "d = \"\"\"x\n\ny\"\"\"\nb\n", [], [], !T, !IO),
    check_trivia("no trivia at all", "a\nb\n", [], [], !T, !IO),
    check("a token after two comments is on its own line",
        ( if
            llex_5_4_lex("# one\nx # two\ny\n", lex_ok(Lines2)),
            Lines2 = [L1, L2],
            L1 ^ sl_tokens = [P1],
            L2 ^ sl_tokens = [P2],
            P1 ^ tk_pos = pos(2, 0),
            P2 ^ tk_pos = pos(3, 0)
        then yes else no ), !T, !IO).

%-----------------------------------------------------------------------------%
% dump-ast -- the tree `ds_ast` reads
%-----------------------------------------------------------------------------%
%
% Asserted on the rendered JSON, whose keys `ds_ast` reads.

:- pred dumped(string::in, string::out) is semidet.

dumped(Src, Json) :-
    parse_front(Src, front_ok(Cst, Toks, Trivia)),
    astjson_file(Src, Cst, Toks, Trivia, astjson_ok(Json)).

:- pred check_dump_has(string::in, string::in, list(string)::in,
                       tally::in, tally::out, io::di, io::uo) is det.

check_dump_has(Name, Src, Wants, !T, !IO) :-
    ( if
        dumped(Src, Json),
        all [W] ( list.member(W, Wants) => string.sub_string_search(Json, W, _) )
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- func occurrences(string, string) = int.

occurrences(Hay, Needle) = N :-
    ( if string.sub_string_search(Hay, Needle, I) then
        N = 1 + occurrences(string.right(Hay,
            string.length(Hay) - I - string.length(Needle)), Needle)
    else
        N = 0
    ).

    % `dsc.strlit`, the one reader of a string's escapes and sites.
    %
:- pred test_strlit(tally::in, tally::out, io::di, io::uo) is det.

test_strlit(!T, !IO) :-
    Pieces = lgra_2_9_6_7_pieces(string.to_char_list(
        "x{{y}}{a.b:.2f}{\\\"v\\\"}{ñame}")),
    check("[LGRA.2.9.6.7] runs, escaped braces, a site, a JSON brace, a "
            ++ "Unicode site",
        ( if
            Pieces = [p_text(T1), p_site(S1), p_text(T2), p_site(S2)],
            string.from_char_list(T1) = "x{y}",
            string.from_char_list(S1) = "a.b:.2f",
            string.from_char_list(T2) = "{\\\"v\\\"}",
            string.from_char_list(S2) = "ñame"
        then yes else no ), !T, !IO),
    check("[LGRA.2.9.6.7] `{}` is an empty site and an unclosed `{` ends it",
        ( if
            lgra_2_9_6_7_pieces(string.to_char_list("a{}b{c")) =
                [p_text(['a']), p_empty, p_text(['b']), p_unclosed(U)],
            string.from_char_list(U) = "{c"
        then yes else no ), !T, !IO),
    check("[LGRA.2.9.6.1] a site's leading NAME is the lexer's identifier",
        ( if
            lgra_2_9_6_1_path(string.to_char_list("ñame.x[0]"), "ñame"),
            not lgra_2_9_6_1_path(string.to_char_list("a b"), _),
            not lgra_2_9_6_1_path(string.to_char_list("a."), _)
        then yes else no ), !T, !IO),
    check("[LGRA.2.9.4] escapes decode",
        ( if
            lgra_2_9_4_decode(string.to_char_list("a\\x41\\u00e9\\n")) =
                decoded(Cs),
            string.from_char_list(Cs) = "aAé\n"
        then yes else no ), !T, !IO),
    check("[LGRA.2.9.7] `\\'` decodes to an apostrophe",
        ( if
            lgra_2_9_4_decode(string.to_char_list("it\\'s")) = decoded(Ap),
            string.from_char_list(Ap) = "it's"
        then yes else no ), !T, !IO),
    % A `String` holds no U+0000 ([LSTR.1.1]), so every escape naming it is
    % a bad escape, and so is `\0`.
    check("[LGRA.2.9.4] an escape naming U+0000 is a bad escape",
        ( if
            lgra_2_9_4_decode(string.to_char_list("\\0")) = bad_escape(_),
            lgra_2_9_4_decode(string.to_char_list("\\x00")) = bad_escape(_),
            lgra_2_9_4_decode(string.to_char_list("\\u0000")) = bad_escape(_),
            lgra_2_9_4_decode(string.to_char_list("\\U00000000")) =
                bad_escape(_),
            lgra_2_9_4_decode(string.to_char_list("\\x01")) = decoded(['\x01\'])
        then yes else no ), !T, !IO),
    check("[LGRA.2.9.4] the other bad escapes",
        ( if
            lgra_2_9_4_decode(string.to_char_list("\\x4")) = bad_escape(_),
            lgra_2_9_4_decode(string.to_char_list("\\uD800")) = bad_escape(_)
        then yes else no ), !T, !IO),
    check_dump_has("dump-ast:an interpolated message is a JoinedStr",
        "rule r:\n    S s\n->\n    log info \"v={s.v:.2f} {{x}}\"\n",
        ["\"_type\":\"JoinedStr\",\"values\":[{\"_type\":\"Constant\","
            ++ "\"value\":\"v=\"",
         "\"_type\":\"FormattedValue\",\"value\":{\"_type\":\"Attribute\"",
         "\"format_spec\":\".2f\"",
         "\"value\":\" {x}\""], !T, !IO),
    check_dump_has("dump-ast:a string's value is decoded, its raw is not",
        "const C = \"a\\tb\\x41\"\n",
        ["\"value\":\"a\\tbA\",\"raw\":\"\\\"a\\\\tb\\\\x41\\\"\""], !T, !IO),
    check_dump_has("dump-ast:a site whose body is not an expression is text",
        "rule r:\n    S s\n->\n    log info \"{bad json here} {s.v}\"\n",
        ["\"values\":[{\"_type\":\"Constant\",\"value\":\"{bad json here} \"",
         "\"_type\":\"FormattedValue\""], !T, !IO),
    check_dump_has("dump-ast:a string of such sites alone is a Constant",
        "const C = \"{bad json here}\"\n",
        ["\"_type\":\"Constant\",\"value\":\"{bad json here}\""], !T, !IO),
    check_dump_has("[LTSL.2.1] a test block is parsed and dumped whole",
        "test \"t\":\n    inputs:\n        at 0_s:\n            S k: 1\n"
            ++ "    produces:\n        never emitted T k: 1\n"
            ++ "        wm count S == 1\n",
        ["\"_type\":\"Test\",\"name\":{\"_type\":\"Constant\",\"value\":\"t\"",
         "\"_type\":\"At\",\"when\":{\"_type\":\"Quantity\"",
         "\"_type\":\"Fact\",\"schema\":{\"_type\":\"TypeName\","
            ++ "\"name\":\"S\"}",
         "\"_type\":\"Assertion\",\"never\":true,\"head\":{\"_type\":"
            ++ "\"Emitted\"",
         "\"_type\":\"WmCount\",\"schema\":{\"_type\":\"TypeName\","
            ++ "\"name\":\"S\"}"], !T, !IO),
    check_dump_has("LTSL.4.4 a test names a schema as `lib.Name` too",
        "test \"t\":\n    inputs:\n        at 0_s:\n            ha.S k: 1\n"
            ++ "    produces:\n        wm count ha.S == 1\n",
        ["\"_type\":\"Fact\",\"schema\":{\"_type\":\"QualifiedType\","
            ++ "\"library\":[\"ha\"],\"name\":\"S\"}",
         "\"_type\":\"WmCount\",\"schema\":{\"_type\":\"QualifiedType\","
            ++ "\"library\":[\"ha\"],\"name\":\"S\"}"], !T, !IO),
    check("[LTSL.8.2] a head that is not one is a syntax error",
        ( if
            parse_front("test \"t\":\n    produces:\n        seen S\n",
                front_stopped(_, _, _, _))
        then yes else no ), !T, !IO),
    % [LGRA.21.1]'s `test_match ::= where_binding | kwarg*`: slot arguments or
    % a binding, never both ([LTSL.8.4]). Each alone parses.
    check("[LTSL.8.4] an `emitted` head with a binding alone parses",
        ( if
            parse_front("test \"t\":\n    produces:\n"
                ++ "        emitted T t where t.k > 0\n", front_ok(_, _, _))
        then yes else no ), !T, !IO),
    check("[LTSL.8.4] an `emitted` head with slot arguments alone parses",
        ( if
            parse_front("test \"t\":\n    produces:\n"
                ++ "        emitted T k: 1\n", front_ok(_, _, _))
        then yes else no ), !T, !IO),
    check_parse_error("[LTSL.8.4] an `emitted` head with both is refused",
        "test \"t\":\n    produces:\n        emitted T k: 1 t where t.k > 0\n",
        pe_test_match_both("emitted"), !T, !IO),
    check_parse_error("[LTSL.8.4] a `published` head with both is refused",
        "test \"t\":\n    produces:\n"
            ++ "        published T k: 1 t where t.k > 0\n",
        pe_test_match_both("published"), !T, !IO),
    check("dump-ast:a bad escape stops the dump as a syntax error",
        ( if
            Src = "const C = \"a\\qb\"\n",
            parse_front(Src, front_ok(Cst, Toks, Trivia)),
            astjson_file(Src, Cst, Toks, Trivia, astjson_stopped(_, _))
        then yes else no ), !T, !IO).

:- pred test_dump_ast(tally::in, tally::out, io::di, io::uo) is det.

test_dump_ast(!T, !IO) :-
    Src = "# head\nuse default\n\nschema S scope ttl 5_min:  # after\n"
        ++ "    k: String key\n    v: Int mutable\n\n"
        ++ "schema Lock scope activation:\n    k: String key\n\n\n"
        ++ "rule r:\n"
        ++ "    S s where s.v > 0x1F and s.v < 100 and s.k == \"x\"\n"
        ++ "->\n    log info \"hi\"\n# tail\n",
    check_dump_has("dump-ast:a leading comment goes before the node after it", Src,
        ["\"_type\":\"Use\",\"dialect\":\"default\",\"settings\":[],"
            ++ "\"lineno\":2,\"col_offset\":0,\"end_lineno\":null,"
            ++ "\"end_col_offset\":null,\"comments_before\":[{\"_type\":"
            ++ "\"comment\",\"text\":\"# head\",\"lineno\":1,"
            ++ "\"col_offset\":0,\"blank_lines_before\":0}]"], !T, !IO),
    check_dump_has("dump-ast:a trailing comment goes on the node its line opens",
        Src, ["\"comment_after\":{\"_type\":\"comment\",\"text\":\"# after\","
            ++ "\"lineno\":4,"], !T, !IO),
    check_dump_has("dump-ast:a blank run goes on the node after it", Src,
        ["\"lineno\":12,\"col_offset\":0,\"end_lineno\":null,"
            ++ "\"end_col_offset\":null,\"comments_before\":[],"
            ++ "\"comment_after\":null,\"blank_lines_before\":2"], !T, !IO),
    check_dump_has("dump-ast:a comment no node follows is the module's last", Src,
        ["\"comments_end\":[{\"_type\":\"comment\",\"text\":\"# tail\""],
        !T, !IO),
    check_dump_has("dump-ast:a literal keeps its spelling beside its value", Src,
        ["\"value\":31,\"raw\":\"0x1F\""], !T, !IO),
    check_dump_has("dump-ast:the `scope ttl` span is parsed into an expression",
        Src, ["\"_type\":\"Ttl\",\"duration\":{\"_type\":\"Quantity\"",
            "\"raw\":\"5_min\""], !T, !IO),
    check_dump_has("dump-ast:a log message keeps its quotes in `raw`", Src,
        ["\"_type\":\"Log\",\"level\":{\"_type\":\"LogInfo\"},\"message\":"
            ++ "{\"_type\":\"Constant\",\"value\":\"hi\",\"raw\":\"\\\"hi\\\"\""],
        !T, !IO),
    % The CST nests `a and b and c` to the left; Python's `ast` is flat.
    check("dump-ast:an `and` chain is one flat BoolOp",
        ( if
            dumped(Src, Json),
            occurrences(Json, "\"_type\":\"BoolOp\"") = 1,
            occurrences(Json, "\"_type\":\"Compare\"") = 3
        then yes else no ), !T, !IO),
    check("dump-ast:a syntax error stops the dump with a front-end code",
        ( if parse_front("schema\n", front_stopped(_, _, _, _)) then yes
        else no ), !T, !IO),
    % The literal ends its line, where layout puts a zero-width `newline`.
    check("dump-ast:a literal ending its line keeps its spelling",
        ( if
            dumped("const N = 0x2A\n", Json3),
            string.sub_string_search(Json3, "\"value\":42,\"raw\":\"0x2A\"", _)
        then yes else no ), !T, !IO),
    % A based literal's `_` counts toward its width: the `1` is at column 20.
    check("[LLEX.11.1] a hex separator is part of the literal's width",
        ( if
            dumped("const N = 0xFF_FF + 1\n", Json4),
            string.sub_string_search(Json4, "\"raw\":\"0xFF_FF\"", _),
            string.sub_string_search(Json4,
                "\"value\":1,\"raw\":\"1\",\"lineno\":1,\"col_offset\":20", _)
        then yes else no ), !T, !IO),
    % An `Attribute` ends just past its name, as every node's end is in
    % Python's `ast`: `s.slot` at column 14 ends at 20.
    check_dump_has("dump-ast:an Attribute ends just past its name",
        "rule r:\n    S s where s.slot > 1\n->\n    log info \"x\"\n",
        ["\"attr\":\"slot\",\"lineno\":2,\"col_offset\":14,"
            ++ "\"end_lineno\":2,\"end_col_offset\":20"], !T, !IO),
    check("dump-ast:the output is JSON-escaped",
        ( if
            dumped("rule r:\n    S s\n->\n    log info \"a\\tb\"\n", Json2),
            string.sub_string_search(Json2, "\"raw\":\"\\\"a\\\\tb\\\"\"", _)
        then yes else no ), !T, !IO).

:- pred test_lex(tally::in, tally::out, io::di, io::uo) is det.

test_lex(!T, !IO) :-
    % [LLEX.8.1.2]: there is no `<-`.
    check_toks("[LLEX.8.1.2] `a<-b` is `a` `<` `-` `b`", "a<-b",
        [name("a"), lt, minus, name("b")], !T, !IO),

    check_toks("[LLEX.8.1.2] `a<=b` is `a` `<=` `b`", "a<=b",
        [name("a"), le, name("b")], !T, !IO),

    % [LLEX.10.8.5]'s three vectors: the first two are one token stream.
    check_toks("[LLEX.10.8.5] `x::Int??d` munches `??`", "x::Int??d",
        [name("x"), coloncolon, name("Int"), question2, name("d")], !T, !IO),

    check_toks("[LLEX.10.8.5] `x::Int ?? d` is the same stream",
        "x::Int ?? d",
        [name("x"), coloncolon, name("Int"), question2, name("d")], !T, !IO),

    check_toks("[LLEX.10.8.5] `x::Int? ?? d` is `?` then `??`",
        "x::Int? ?? d",
        [name("x"), coloncolon, name("Int"), question, question2, name("d")],
        !T, !IO),

    % A vector per rung of [LLEX.11.3.1]'s ladder ([LLEX.12.1.1]). Rung 1,
    % UNIT_LIT, is taken first.
    check_toks("ladder rung 1: `30s` is one unit literal", "30s",
        [unit_lit("30", "s")], !T, !IO),

    % [LUNI.3.1.4]: a digit followed by a letter is a unit literal whatever
    % the letter, so `30x` is one token.
    check_toks("[LUNI.3.1.4] `30x` is a unit literal, not `30 * x`", "30x",
        [unit_lit("30", "x")], !T, !IO),

    % Rung 2: a scientific float, since [LUNI.3.1.5] withholds `e`+digits
    % from UNIT_SUFFIX.
    check_toks("ladder rung 2: `1e6` is a float, not a unit literal", "1e6",
        [float_lit(1000000.0)], !T, !IO),

    check_toks("`1.5e-3` carries its sign", "1.5e-3",
        [float_lit(0.0015)], !T, !IO),

    % [LUNI.3.1.5] withholds `e` followed by digits, not `e` alone: `5e` is a
    % unit literal naming a unit `e`, refused at resolve ([LUNI.3.1.7]).
    check_toks("[LUNI.3.1.5] `5e` is a unit literal, not a malformed float",
        "5e", [unit_lit("5", "e")], !T, !IO),

    % And the other side of the same rule: `e` followed by a letter is a unit
    % ([LUNI.3.1.5]'s own example, electronvolts).
    check_toks("[LUNI.3.1.5] `1eV` is electronvolts, not a float", "1eV",
        [unit_lit("1", "eV")], !T, !IO),

    % A bare `i`/`j` is withheld from UNIT_SUFFIX ([LUNI.3.1.5],
    % [LLEX.11.3.1]). On a number it is [LUNI.14.9]'s complex literal, refused
    % as such (`DS_VALIDATE_COMPLEX_NOT_IN_V1`, raised by the driver).
    check_lex_error("[LUNI.14.9] `5i` is the complex literal", "5i",
        lx_complex_literal("5i"), !T, !IO),
    check_lex_error("[LUNI.14.9] `2.5j` likewise", "2.5j",
        lx_complex_literal("2.5j"), !T, !IO),
    check_lex_error("[LUNI.14.9] `1e3i` likewise", "1e3i",
        lx_complex_literal("1e3i"), !T, !IO),

    % `5_i` is not the complex literal, and reaches no token class.
    check_lex_error("[LUNI.3.1.5] `5_i` reaches no token class", "5_i",
        lx_bare_imaginary("5_i"), !T, !IO),

    % `i` is withheld only when bare: `5in` is inches ([LUNI.3.1.5]).
    check_toks("[LUNI.3.1.5] `5in` is inches, `i` is withheld only when bare",
        "5in", [unit_lit("5", "in")], !T, !IO),

    % [LLEX.11.2.2]: the bare form needs an exponent to be a float.
    check_toks("[LLEX.11.2.2] a bare digit run with no exponent is an int",
        "5", [int_lit(5i64)], !T, !IO),

    % [LLEX.11.2.2]: the dotted form needs none.
    check_toks("[LLEX.11.2.2] the dotted form needs no exponent", "5.0",
        [float_lit(5.0)], !T, !IO),

    % [LLEX.11.2.3]: a based literal is an integer, so `0x1` ends at the `.`,
    % and the `.8` is [LLEX.11.2.1]'s bare-fraction error.
    check_lex_error("[LLEX.11.2.3] a hex float is refused, via the `.` rule",
        "0x1.8p3", lx_bare_fraction, !T, !IO),

    % [LLEX.11.2.3], [LUNI.3.1.4]: a name adjacent to a number is a unit
    % suffix, so `5L` names a unit `L`.
    check_toks("[LLEX.11.2.3] `5L` is a unit literal, not a typed suffix",
        "5L", [unit_lit("5", "L")], !T, !IO),

    % [LLEX.12.1]: in the numeric prefix a `_` before a digit is a group
    % separator; the one before the suffix is not.
    check_toks("[LLEX.12.1] `23_000_m` is one unit literal of 23000",
        "23_000_m", [unit_lit("23_000", "_m")], !T, !IO),

    check_toks("`1_000` is an int with separators", "1_000",
        [int_lit(1000i64)], !T, !IO),

    % [LLEX.5.1] / [LLEX.5.2]: neither a comment-only line nor a blank line
    % reaches the layout pass.
    check_lines("[LLEX.5.2] blank and comment-only lines vanish",
        "a\n\n# just a comment\n   \nb\n", 2, !T, !IO),

    check_lines("a trailing comment does not kill its line",
        "a  # trailing\n", 1, !T, !IO),

    % [LLEX.8.2.3]: refused as one token, so the diagnostic names it.
    check_lex_error("[LLEX.8.2.3] `...` is one named error", "a ... b",
        lx_ellipsis, !T, !IO),

    check_lex_error("a lone `!` is a lexer error", "a ! b",
        lx_lone_bang, !T, !IO),

    % [LLEX.10.6.1]: nothing is reserved, so `__foo__` and `__foo` are names.
    check_toks("[LLEX.10.6.1] `__foo__` is a name", "__foo__",
        [name("__foo__")], !T, !IO),
    check_toks("[LLEX.10.6.1] `__foo` is a name", "__foo",
        [name("__foo")], !T, !IO),

    % [LLEX.10.6.1]: a synthetic name has no surface form. `$` is no
    % identifier character ([LLEX.10]), so `$ClockTick` written in source is
    % refused at its first character, and no author name can equal one.
    check_lex_error("[LLEX.10.6.1] `$ClockTick` is no token", "$ClockTick",
        lx_bad_char('$'), !T, !IO),

    % Content is kept raw: interpolation is a later pass ([LLEX.13.2.1]).
    check_toks("a string keeps its braces and its escapes",
        "\"a {x} b\"", [single_str("a {x} b")], !T, !IO),

    % [LLEX.11.2.1]: both sides of the decimal point are required. A slot
    % name cannot begin with a digit, so `.5` is never slot access.
    check_lex_error("[LLEX.11.2.1] `.5` is a lexer error", "x = .5",
        lx_bare_fraction, !T, !IO),

    check_lex_error("[LLEX.11.2.1] `5.` is a lexer error", "5.",
        lx_bare_fraction, !T, !IO),

    % [LLEX.11.1]: `_` at either end of a literal.
    check_lex_error("[LLEX.11.1] `42_` is misplaced", "42_",
        lx_underscore_placement("42_"), !T, !IO),

    % [LLEX.11.1]: `_` adjacent to a base prefix.
    check_lex_error("[LLEX.11.1] `0x_FF` is misplaced", "0x_FF",
        lx_underscore_placement("0x_"), !T, !IO),

    % [LLEX.11.1], [LLEX.11.2]: `DIGIT ('_'? DIGIT)*`. A second `_` is no unit
    % separator: [LUNI.3.2]'s UNIT_SUFFIX opens with a UNIT_START, and `_` is
    % UNIT_CONT only.
    check_lex_error("[LLEX.11.1] `1__2` is misplaced", "1__2",
        lx_underscore_placement("1_"), !T, !IO),
    check_lex_error("[LLEX.11.1] `0x1__F` is misplaced", "0x1__F",
        lx_underscore_placement("0x1_"), !T, !IO),
    check_lex_error("[LLEX.11.2] `1.2__5` is misplaced", "1.2__5",
        lx_underscore_placement("1.2_"), !T, !IO),
    check_lex_error("[LLEX.11.2] `1e1__0` is misplaced", "1e1__0",
        lx_underscore_placement("1e1_"), !T, !IO),
    check_lex_error("[LUNI.3.2] `5__s` is misplaced, not a unit `_s`", "5__s",
        lx_underscore_placement("5_"), !T, !IO),
    check_toks("[LUNI.3.1] `5_s` is still one unit literal", "5_s",
        [unit_lit("5", "_s")], !T, !IO),

    % [LLEX.11.1]: the three integer bases.
    check_toks("[LLEX.11.1] `0xFF` is 255", "0xFF",
        [int_lit(255i64)], !T, !IO),
    check_toks("[LLEX.11.1] `0b1010` is 10", "0b1010",
        [int_lit(10i64)], !T, !IO),
    check_toks("[LLEX.11.1] `0o17` is 15", "0o17",
        [int_lit(15i64)], !T, !IO),

    % [LUNI.3.1.8]: no based prefix on a unit literal.
    check_lex_error("[LUNI.3.1.8] `0xFF_Hz` is not a unit literal",
        "0xFF_Hz", lx_based_unit("0xFF"), !T, !IO),
    check_lex_error("[LUNI.3.1.8] nor is `0xffs`, with no separator",
        "0xffs", lx_based_unit("0xff"), !T, !IO),
    check_lex_error("[LUNI.3.1.8] nor a binary prefix on a unit",
        "0b1_KiB", lx_based_unit("0b1"), !T, !IO),

    % [LUNI.3.1.8]: `_` is a HEX_LIT separator and `A` and `F` are hex
    % digits, so both are integers.
    check_toks("[LUNI.3.1.8] `0xFF_A` is 4090, not 255 amperes", "0xFF_A",
        [int_lit(4090i64)], !T, !IO),
    check_toks("[LUNI.3.1.8] `0xFF_FF` is 65535", "0xFF_FF",
        [int_lit(65535i64)], !T, !IO),

    % [LLEX.11.1.5]: an error of its own.
    check_lex_error("[LLEX.11.1.5] an out-of-range integer says so",
        "99999999999999999999",
        lx_int_out_of_range("99999999999999999999"), !T, !IO),

    % [LLEX.11.2.4]: a float literal that would round to an infinity
    % is a lexer error of its own, judged on the ROUNDED value: the two
    % 1.79...e308 rows straddle the threshold 2^1024 - 2^970, and `1e5000` is
    % past every exponent `dsc.exact.from_decimal` takes. One that rounds to
    % zero is that zero, however far below.
    check_lex_error("[LLEX.11.2.4] 1e400 is out of range", "1e400",
        lx_float_out_of_range("1e400"), !T, !IO),
    check_lex_error("[LLEX.11.2.4] past the rounding threshold, below 1e309",
        "1.7976931348623159e308",
        lx_float_out_of_range("1.7976931348623159e308"), !T, !IO),
    check_lex_error("[LLEX.11.2.4] an exponent past any from_decimal takes",
        "1e5000", lx_float_out_of_range("1e5000"), !T, !IO),
    check_lex_error("[LLEX.11.2.4] separators do not hide it", "1_000e306",
        lx_float_out_of_range("1_000e306"), !T, !IO),
    check_lex_error("[LLEX.11.2.4] a unit literal's prefix too", "1e400_m",
        lx_float_out_of_range("1e400"), !T, !IO),
    check_lex_error("[LLEX.11.2.4] an integer-spelled unit prefix too",
        "1" ++ string.duplicate_char('0', 309) ++ "_m",
        lx_float_out_of_range("1" ++ string.duplicate_char('0', 309)),
        !T, !IO),
    check_toks("[LLEX.11.2.4] below the threshold is the largest double",
        "1.7976931348623158e308", [float_lit(float.max)], !T, !IO),
    check_toks("[LLEX.11.2.4] a literal that rounds to zero is zero",
        "1e-5000", [float_lit(0.0)], !T, !IO),
    check_toks("[LLEX.11.2.4] a large mantissa scaled down stays a literal",
        "1" ++ string.duplicate_char('0', 400) ++ ".0e-400", [float_lit(1.0)],
        !T, !IO),

    % [LLEX.12.2]: seven non-ASCII characters are permitted in a unit suffix.
    % The euro sign is not alphabetic, so [LLEX.11.3.1]'s ladder emits `30` as
    % an INT and the character is `lx_bad_char` on its own.
    check_lex_error("[LLEX.12.2] a stray non-ASCII unit character is refused",
        "30\x20AC\", lx_bad_char('\x20AC\'), !T, !IO),

    check_toks("[LLEX.12.2] the degree sign IS a unit character", "45\xB0\",
        [unit_lit("45", "\xB0\")], !T, !IO),

    % [LLEX.12.2.1]: the ohm sign folds to Greek capital omega.
    check_toks("[LLEX.12.2.1] the ohm sign folds to omega", "5\x2126\",
        [unit_lit("5", "\x3A9\")], !T, !IO),

    check_lex_error("an unterminated string does not run to EOF", "\"abc",
        lx_unterminated_string, !T, !IO),

    % `ï` is XID_Continue and Identifier_Status=Allowed, and the name is
    % single-script Latin.
    check_toks("[LNAM.1.1] a non-ASCII identifier lexes", "naïve",
        [name("naïve")], !T, !IO),

    % The lexer NFC-normalises ([LLEX.10.8.2]), so identity downstream is a
    % byte comparison ([LNAM.2.8]).
    check_toks("[LLEX.10.8.2] a decomposed name normalises at lex time",
        "nai\x308\ve", [name("naïve")], !T, !IO),

    % Mixed script is its own error ([LNAM.2.5.1], UAX #39 Highly
    % Restrictive).
    check_lex_error("[LNAM.2.5.1] a Latin/Cyrillic homograph is refused",
        "pa\x443\pal",
        lx_bad_identifier("pa\x443\pal",
            "mixed-script identifier rejected (UAX #39 Highly Restrictive)"),
        !T, !IO),

    % [LLEX.1.1] / [LNAM.2.7.1]: an ill-formed byte is refused where
    % it stands, before a character is decoded. Bytes, because a Mercury
    % `string` literal cannot spell an ill-formed one. Each refusal of Table
    % 3-7 has a case, and its neighbour that is legal is the control.
    Ill = ( func(Units) = Pos :-
        ( if llex_1_1_first_ill_formed(Units, P) then Pos = yes(P)
        else Pos = no )),
    % `a`, a newline, then on line 2 `"é"` -- C3 A9 -- with `€` and an emoji
    % after it; the truncated twin has C3 alone before the closing quote.
    check("[LLEX.1.1] well-formed multi-byte text passes",
        ( if Ill([0x61, 0x0A, 0x22, 0xC3, 0xA9, 0x22,
                  0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80]) = no
          then yes else no ), !T, !IO),
    check("[LLEX.1.1] a truncated sequence is refused at its line and column",
        ( if Ill([0x61, 0x0A, 0x22, 0xC3, 0x22]) = yes(pos(2, 1))
          then yes else no ), !T, !IO),
    check("[LLEX.1.1] a column counts characters, not bytes",
        ( if Ill([0xC3, 0xA9, 0xC3, 0xA9, 0xFF]) = yes(pos(1, 2))
          then yes else no ), !T, !IO),
    check("[LLEX.1.1] a lone continuation byte is refused",
        ( if Ill([0x80]) = yes(pos(1, 0)) then yes else no ), !T, !IO),
    check("[LLEX.1.1] an overlong `/` (C0 AF) is refused",
        ( if Ill([0xC0, 0xAF]) = yes(pos(1, 0)) then yes else no ), !T, !IO),
    check("[LLEX.1.1] an overlong three-byte form (E0 80 80) is refused",
        ( if Ill([0xE0, 0x80, 0x80]) = yes(pos(1, 0)) then yes else no ),
        !T, !IO),
    check("[LLEX.1.1] a surrogate (ED A0 80) is refused",
        ( if Ill([0xED, 0xA0, 0x80]) = yes(pos(1, 0)) then yes else no ),
        !T, !IO),
    check("[LLEX.1.1] but U+D7FF (ED 9F BF) is not a surrogate",
        ( if Ill([0xED, 0x9F, 0xBF]) = no then yes else no ), !T, !IO),
    check("[LLEX.1.1] above U+10FFFF (F4 90 80 80) is refused",
        ( if Ill([0xF4, 0x90, 0x80, 0x80]) = yes(pos(1, 0)) then yes else no ),
        !T, !IO),
    check("[LLEX.1.1] but U+10FFFF (F4 8F BF BF) is admitted",
        ( if Ill([0xF4, 0x8F, 0xBF, 0xBF]) = no then yes else no ), !T, !IO),

    % [LIMP.9.9]: a leading `_` begins a name. A `_` no identifier character
    % follows is refused.
    check_toks("[LIMP.9.9] `_foo` is an identifier", "_foo",
        [name("_foo")], !T, !IO),
    check_lex_error("[LLEX.10.4] a lone `_` is not an identifier", "_ ",
        lx_leading_underscore, !T, !IO),

    % `_` and digits are `XID_Continue`, so [LLEX.10]'s production takes both
    % whole.
    check_toks("[LLEX.10] `__1x__` is a name", "__1x__",
        [name("__1x__")], !T, !IO),
    check_toks("[LLEX.10] `__foo___` is a name", "__foo___",
        [name("__foo___")], !T, !IO),

    % [LLEX.10.5]: `_` inside an identifier.
    check_toks("[LLEX.10.5] `entity_id` keeps its underscore", "entity_id",
        [name("entity_id")], !T, !IO).

%-----------------------------------------------------------------------------%
% Constants and series -- [LGRA.4.1], [LGRA.7.1]
%-----------------------------------------------------------------------------%

:- func one_const(file) = lgra_4_1_const_decl.
:- mode one_const(in) = out is semidet.

one_const(file(_, [td_const(C)])) = C.

:- func one_series(file) = lgra_7_1_series_decl.
:- mode one_series(in) = out is semidet.

one_series(file(_, [td_series(S)])) = S.

:- pred test_decls(tally::in, tally::out, io::di, io::uo) is det.

test_decls(!T, !IO) :-
    % ── const [LGRA.4.1] ────────────────────────────────────────────────────

    check_parse("[LGRA.4.1] `const N = <expr>` is the modern form",
        "const HEAT = 85\n",
        ( pred(F::in) is semidet :-
            C = one_const(F),
            C ^ cd_name ^ id_name = "HEAT",
            C ^ cd_form = cf_value(no, ex_int(85i64, _))
        ), !T, !IO),

    check_parse("[LGRA.4.1] the `:` annotation sits before the `=`",
        "const AREA: Float = 1.0\n",
        ( pred(F::in) is semidet :-
            one_const(F) ^ cd_form = cf_value(
                yes(lgra_6_7_2_annotation(ident("Float", _), non_null)), _)
        ), !T, !IO),

    % [LGRA.4.5]: the `?` is "accepted and inert" -- taken and kept, as
    % [LGRA.6.7.3] does for `let`.
    check_parse("[LGRA.4.5] a `const` annotation's `?` is accepted and kept",
        "const X: Int? = 1\n",
        ( pred(F::in) is semidet :-
            one_const(F) ^ cd_form = cf_value(
                yes(lgra_6_7_2_annotation(_, nullable)), _)
        ), !T, !IO),

    % [LGRA.4.1]: `const N: <literal>` parses, so `validate` can refuse it
    % with DS_VALIDATE_CONST_COLON_LITERAL_RETIRED, naming the fix.
    check_parse("[LGRA.4.1] the retired `const N: <literal>` still parses",
        "const N: 85\n",
        ( pred(F::in) is semidet :-
            one_const(F) ^ cd_form = cf_colon_literal(ex_int(85i64, _))
        ), !T, !IO),

    % Both spellings have a `:`; an `=` after the annotation separates them.
    check_parse("[LGRA.4.1] `const N: Int = 1` is not read as the retired form",
        "const N: Int = 1\n",
        ( pred(F::in) is semidet :-
            one_const(F) ^ cd_form = cf_value(yes(_), _)
        ), !T, !IO),

    % [LGRA.4.1]: the grammar takes any expression; foldability is
    % `validate`'s ([LGRA.13.3], `DS_VALIDATE_CONST_NOT_FOLDABLE`).
    check_parse("[LGRA.4.1] a non-foldable RHS parses, for the validator",
        "const X = a + 1\n",
        ( pred(F::in) is semidet :-
            one_const(F) ^ cd_form = cf_value(no, ex_binary(bo_add, _, _, _))
        ), !T, !IO),

    % ── series [LGRA.7.1] ───────────────────────────────────────────────────

    check_parse("[LGRA.7.3] an unqualified slot_ref names only the slot",
        "series state:\n    mean sliding 10_min\n",
        ( pred(F::in) is semidet :-
            S = one_series(F),
            S ^ sr_slot = lgra_7_3_slot_ref(no, ident("state", _)),
            S ^ sr_lines = [_]
        ), !T, !IO),

    check_parse("[LGRA.7.3] a qualified slot_ref names the schema too",
        "series Sensor.state:\n    min, max sliding 10_min\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_slot =
                lgra_7_3_slot_ref(yes(ident("Sensor", _)), ident("state", _))
        ), !T, !IO),

    % The comma continues the aggregation list; the first name not followed by
    % one ends it.
    check_parse("[LGRA.7.1] `min, max sliding` splits list from model",
        "series s:\n    min, max sliding 10_min\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_aggs = [ident("min", _), ident("max", _)],
            L ^ sl_time = tm_sliding(_, _)
        ), !T, !IO),

    check_parse("[LGRA.7.1] `all_time` takes no argument",
        "series s:\n    mean all_time\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_time = tm_all_time(_)
        ), !T, !IO),

    check_parse("[LGRA.7.1] `sample` takes a count",
        "series s:\n    p95 sample 200\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_time = tm_sample(ex_int(200i64, _), _)
        ), !T, !IO),

    % [LGRA.7.8]'s block-options form, parenthesised before the `:`.
    check_parse("[LGRA.7.8] block options parse before the colon",
        "series s (by: device_id):\n    mean all_time\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_opts = [bk_by(by_name(_), _)]
        ), !T, !IO),
    % [LGRA.7.1], [LSER.13.5]: `persist:` is not in the grammar.
    check_parse_fails("`persist:` is not a block option",
        "series s (by: device_id, persist: 7_d):\n    mean all_time\n",
        !T, !IO),

    check_parse("[LGRA.7.1] `by: none` is the explicit no-grouping form",
        "series s (by: none):\n    mean all_time\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_opts = [bk_by(by_none(_), _)]
        ), !T, !IO),

    % [LGRA.7.1]: an accuracy phrase parses, so the validator's refusal can
    % name it.
    check_parse("[LGRA.7.1] an accuracy phrase parses, for the diagnostic",
        "series s:\n    mean sliding 10_min confidence 0.95\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_accuracy = yes(ac_confidence(_, _))
        ), !T, !IO),

    check_parse("[LGRA.7.1] `bound deterministic` is two words",
        "series s:\n    mean all_time bound deterministic\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_accuracy = yes(ac_bound_deterministic(_))
        ), !T, !IO),

    % [LGRA.7.6a]: `gap hold|zero|skip`, after the time model, with no
    % default filled in: it is valid only on a time-integrating aggregation.
    check_parse("[LGRA.7.6a] a gap policy parses and is not defaulted",
        "series s:\n    integral all_time gap zero\n    mean all_time\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L1, L2],
            L1 ^ sl_gap = yes(gp_zero(_)),
            L2 ^ sl_gap = no
        ), !T, !IO),

    check_parse("[LGRA.7.1] an `as` alias names the line",
        "series s:\n    mean sliding 10_min as avg10\n",
        ( pred(F::in) is semidet :-
            one_series(F) ^ sr_lines = [L],
            L ^ sl_as = yes(ident("avg10", _))
        ), !T, !IO),

    % [LGRA.7.9]: `series_line+`, so a docstring-only body is a grammar error.
    check_parse_error("[LGRA.7.9] a series with no observation lines is refused",
        "series s:\n    \"only a docstring\"\n",
        pe_empty_series, !T, !IO),

    % ── through `build` ─────────────────────────────────────────────────────

    check_built("a const and a series survive `build`",
        "const X = 1\nseries s:\n    mean all_time\n",
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_const(C), ad_series(S)],
            C ^ acn_form = acf_value(no, _),
            S ^ asr_lines = [_]
        ), !T, !IO),

    check_built("[LGRA.4.1] the retired spelling survives `build` intact",
        "const N: 85\n",
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_const(C)],
            C ^ acn_form = acf_colon_literal(_)
        ), !T, !IO),

    % ── service [LGRA.23.1] ─────────────────────────────────────────────────

    check_parse("[LGRA.23.1] a `service` carries kwargs and `response T`",
        "service light.turn_on:\n    kwarg entity_id: String literal required\n"
            ++ "    kwarg brightness: Int default 100\n"
            ++ "    response HALightResponse\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_service(S)],
            S ^ sv_name = [ident("light", _), ident("turn_on", _)],
            S ^ sv_kwargs = [K1, K2],
            K1 ^ sk_modifiers = [km_literal(_), km_required(_)],
            K2 ^ sk_modifiers = [km_default(ex_int(100i64, _), _)],
            S ^ sv_response = rd_schema(ident("HALightResponse", _)),
            S ^ sv_hydration = []
        ), !T, !IO),

    check_parse("[LGRA.23.1] `no response` is a response line",
        "service ping:\n    kwarg url: String\n    no response\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_service(S)],
            S ^ sv_response = rd_none(_)
        ), !T, !IO),

    % LGRA.23.2: a missing response line is the validator's refusal
    % (DS_VALIDATE_SERVICE_NO_RESPONSE_DECL), so the parser records it.
    check_parse("LGRA.23.2: a service with no response line parses as absent",
        "service ping:\n    kwarg url: String\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_service(S)],
            S ^ sv_response = rd_absent
        ), !T, !IO),

    % Neither `response: T` nor a `hydration:` block is in the grammar.
    check_parse_fails("LGRA.23.1: `response: T` is not the spelling",
        "service s:\n    response: R\n", !T, !IO),
    check_parse_fails("a `hydration:` block does not parse",
        "service s:\n    no response\n    hydration:\n        max_limit: 50\n",
        !T, !IO),

    % ── opaque [LOPQ.2.1] ───────────────────────────────────────────────────

    check_parse("[LOPQ.2.1] `opaque type X over Bytes` parses",
        "opaque type Key over Bytes\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_opaque(O)],
            O ^ op_name ^ id_name = "Key",
            O ^ op_repr ^ id_name = "Bytes"
        ), !T, !IO),

    % [LOPQ.10.1] admits only `Bytes`; another representation parses, for
    % `DS_VALIDATE_OPAQUE_UNSUPPORTED_REPR`.
    check_parse("[LOPQ.10.1] an unsupported repr parses, for the validator",
        "opaque type Key over String\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_opaque(O)],
            O ^ op_repr ^ id_name = "String"
        ), !T, !IO),

    % `over` is reserved ([LLEX.9.6]), and `validate` refuses the slot
    % ([LLEX.9.5]); the parser takes it.
    check_parse("a slot named `over` parses (validate refuses it)",
        "schema S:\n    over: Int\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_fields = [Fld],
            Fld ^ fd_name ^ id_name = "over"
        ), !T, !IO),

    check_parse_fails("an `opaque` missing its `over` clause is refused",
        "opaque type Key\n", !T, !IO),

    check_built("an opaque type survives `build`",
        "opaque type Key over Bytes\n",
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_opaque(O)],
            O ^ aop_name ^ id_name = "Key",
            O ^ aop_repr ^ id_name = "Bytes"
        ), !T, !IO),

    check_built("a service survives `build`",
        "service s:\n    kwarg a: Int\n    no response\n",
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_service(S)],
            S ^ asv_kwargs = [_],
            S ^ asv_response = ar_none(_)
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% The rule body -- [LGRA.6.1], [LGRA.10.1], [LTAC.2.1]
%-----------------------------------------------------------------------------%

    % The RHS of a one-pattern rule whose body is `Body`.
    %
:- func rule_with_body(string) = string.

rule_with_body(Body) = "rule r:\n    Motion m\n->\n" ++ Body.

:- func one_rhs(file) = lgra_6_1_rule_rhs.
:- mode one_rhs(in) = out is semidet.

one_rhs(F) = one_rule(F) ^ rd_rhs.

:- pred check_rhs(string, string, pred(lgra_6_1_rule_rhs), tally, tally,
                  io, io).
:- mode check_rhs(in, in, pred(in) is semidet, in, out, di, uo) is det.

check_rhs(Name, Body, Wanted, !T, !IO) :-
    ( if front(rule_with_body(Body), F), R = one_rhs(F), Wanted(R) then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_rhs(tally::in, tally::out, io::di, io::uo) is det.

test_rhs(!T, !IO) :-
    % ── actions [LGRA.10.1] ─────────────────────────────────────────────────

    % [LGRA.10.1.1]: `log_level` is case-insensitive, classified by the
    % parser.
    check_rhs("[LGRA.10.1.1] a log level is case-insensitive",
        "    log INFO \"x\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_log(ll_info, "x")
        ), !T, !IO),

    check_rhs("[LGRA.10.1] `emit` names a schema", "    emit Alert\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_emit(tr_bare(ident("Alert", _)))
        ), !T, !IO),

    check_rhs("LGRA.10.1 `emit` takes a pattern's `lib.Name`",
        "    emit ha.core.Alert\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_emit(tr_qualified(
                [ident("ha", _), ident("core", _)], ident("Alert", _)))
        ), !T, !IO),

    check_rhs("LGRA.10.1 `publish` and `record_event` take `lib.Name` too",
        "    publish ha.Alert\n    record_event ha.Seen\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [P, E],
            P ^ ac_head = ah_publish(tr_qualified([ident("ha", _)],
                ident("Alert", _))),
            E ^ ac_head = ah_record_event(tr_qualified([ident("ha", _)],
                ident("Seen", _)))
        ), !T, !IO),

    check_rhs("[LGRA.10.1] `cache_delete` takes no name",
        "    cache_delete key: \"k\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_cache_delete
        ), !T, !IO),

    check_rhs("`cache` and `cache_delete` are distinct verbs",
        "    cache key: \"k\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_cache
        ), !T, !IO),

    % [LGRA.10.1]: `service_ref ::= service_name`, and the name is dotted.
    check_rhs("[LGRA.10.1] a bare service name may be dotted",
        "    call light.turn_on entity_id: \"x\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_call(sr_bare([ident("light", _),
                ident("turn_on", _)]))
        ), !T, !IO),

    % [LGRA.22.9]: a `call` position is not resolved by scope, and no service
    % is library-qualified ([LGRA.10.1.6]), so every segment is the service's
    % name.
    check_rhs("[LGRA.10.1] a service path is all service name",
        "    call ha.light.turn_on entity_id: \"x\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_head = ah_call(sr_bare([ident("ha", _),
                ident("light", _), ident("turn_on", _)]))
        ), !T, !IO),

    % ── action arguments [LGRA.10.3.1] ──────────────────────────────────────

    % A flag and a kwarg both start at a `NAME`; the `:` separates them. DS
    % has no application syntax, so `100` ends where no operator follows.
    check_rhs("[LGRA.10.3.1] kwargs and flags mix on one action",
        "    emit Alert level: 100 urgent\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_args = [aa_kwarg(ident("level", _), ex_int(100i64, _), _),
                           aa_flag(ident("urgent", _))]
        ), !T, !IO),

    % [LGRA.10.3.2]: the grammar accepts any kwarg/flag sequence; the per-verb
    % contract is enforced later.
    check_rhs("[LGRA.10.3.2] an unknown kwarg still parses",
        "    emit Alert wibble: 1\n",
        ( pred(R::in) is semidet :- R ^ rr_actions = [_] ), !T, !IO),

    % [LGRA.10.2]: one logical line per action, continued by brackets
    % ([LLEX.7.3]).
    check_rhs("[LGRA.10.2] a parenthesised value continues the line",
        "    emit Alert level: (\n        1 + 2\n    )\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_args = [aa_kwarg(_, ex_binary(bo_add, _, _, _), _)]
        ), !T, !IO),

    check_rhs("several actions become several entries",
        "    log info \"a\"\n    log info \"b\"\n",
        ( pred(R::in) is semidet :- R ^ rr_actions = [_, _] ), !T, !IO),

    % ── `let` [LGRA.6.1], [LGRA.6.7] ────────────────────────────────────────

    check_rhs("[LGRA.6.7.1] a `let` precedes the actions",
        "    let x = 1\n    log info \"a\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_lets = [L],
            L ^ ld_bindings = [lb_simple(ident("x", _), no, ex_int(1i64, _), _)],
            R ^ rr_actions = [_]
        ), !T, !IO),

    % [LGRA.6.7.2]: `NAME (':' TYPE_SYM NULLABLE?)? '=' expression`.
    check_rhs("[LGRA.6.7.2] a `let` may carry a type annotation",
        "    let x: Int = 1\n    log info \"a\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_lets = [L],
            L ^ ld_bindings = [lb_simple(_,
                yes(lgra_6_7_2_annotation(ident("Int", _), non_null)), _, _)]
        ), !T, !IO),

    % [LGRA.6.7.3]: the `?` on a `let` annotation is accepted and inert, and
    % kept.
    check_rhs("[LGRA.6.7.3] a `let` annotation's `?` is accepted and kept",
        "    let x: Int? = 1\n    log info \"a\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_lets = [L],
            L ^ ld_bindings = [lb_simple(_,
                yes(lgra_6_7_2_annotation(_, nullable)), _, _)]
        ), !T, !IO),

    % [LREG.4.1]'s capture form, [LGRA.6.1]'s second alternative, told by its
    % `(`.
    check_rhs("[LGRA.6.1] the capture form binds a tuple",
        "    let (a, b) = x\n    log info \"z\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_lets = [L],
            L ^ ld_bindings = [lb_capture([ident("a", _), ident("b", _)],
                _, _)]
        ), !T, !IO),

    % [LGRA.6.7.4]'s hanging-indent form is one `let_decl` holding a group,
    % its first binding on the `let` line ([LGRA.6.1]: `'let' let_binding
    % (INDENT let_binding+ DEDENT)?`).
    check_rhs("[LGRA.6.7.4] the hanging-indent form groups its bindings",
        "    let a = 1\n        b = 2\n    log info \"z\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_lets = [L],
            L ^ ld_bindings = [_, _]
        ), !T, !IO),

    % ── `after` [LTAC.2.1] ──────────────────────────────────────────────────

    check_rhs("[LTAC.2.1] an `after` clause follows the actions",
        "    log info \"a\"\n    after 30_s:\n        log info \"b\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [_],
            R ^ rr_afters = [A],
            A ^ af_duration = ex_unit("30", "_s", _),
            A ^ af_actions = [_]
        ), !T, !IO),

    % [LTAC.2.2.1]: the optional `as <expr>` declares a correlation key.
    check_rhs("[LTAC.2.2.1] `after ... as <expr>` carries a correlation key",
        "    log info \"a\"\n    after 30_s as m.id:\n        log info \"b\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_afters = [A],
            A ^ af_as = yes(ex_slot(_, _, _))
        ), !T, !IO),

    % An `after`-only body is legal, though [LGRA.6.1] and [LTAC.2.1] each
    % write an immediate action list.
    check_rhs("a rule may have only `after` clauses",
        "    after 30_s:\n        log info \"b\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [],
            R ^ rr_afters = [_]
        ), !T, !IO),

    check_rhs("a nested `after` sits inside its parent's block",
        "    log info \"a\"\n    after 30_s:\n        log info \"b\"\n"
            ++ "        after 10_s:\n            log info \"c\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_afters = [A],
            A ^ af_nested = [_]
        ), !T, !IO),

    % [LGRA.6.1], [LTAC.2.2]: the duration is one `UNIT_LIT` token. A
    % computed, named, parenthesised or negated duration does not parse.
    list.foldl2(
        ( pred({What, Dur}::in, T0::in, T1::out, IO0::di, IO1::uo) is det :-
            Body = "    log info \"a\"\n    after " ++ Dur
                ++ ":\n        log info \"b\"\n",
            Ok = ( if front(rule_with_body(Body), _) then no else yes ),
            check("[LTAC.2.2] a " ++ What ++ " `after` duration does not parse",
                Ok, T0, T1, IO0, IO1)
        ),
        [{"computed", "x + 1"}, {"named", "m.delay"},
         {"parenthesised", "(30_s)"}, {"negated", "-5_s"},
         {"literal-plus-literal", "30_s + 1_s"}],
        !T, !IO),

    % ── what is refused ─────────────────────────────────────────────────────

    % ── indented action bodies [LGRA.10.8], [LCCO.2.1] ──────────────────────

    % [LGRA.10.8]'s argument lines under an `emit`.
    check_rhs("an `emit` may carry an indented kwarg block",
        "    emit Alert\n        level: 1\n        urgency: 2\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_block = ab_kwargs([_, _])
        ), !T, !IO),

    % [LCCO.2.1]'s three continuation forms.
    check_rhs("[LCCO.2.1] `call` takes `on` / `timeout` / `error`",
        "    call svc a: 1\n        on r.ok:\n            log info \"b\"\n"
            ++ "        timeout 5_s:\n            log info \"c\"\n"
            ++ "        error:\n            log info \"d\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_block = ab_call([], [cont_on(_, [_], _),
                cont_timeout(_, [_], _), cont_error(no, [_], _)])
        ), !T, !IO),

    % [LCCO.2.1]: `error`'s code pattern is optional; bare `error:` is the
    % catch-all.
    check_rhs("[LCCO.2.1] `error` may carry a dotted code pattern",
        "    call svc a: 1\n        error adapter.throttled:\n"
            ++ "            log info \"b\"\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_block = ab_call(_, [cont_error(yes([ident("adapter", _),
                ident("throttled", _)]), _, _)])
        ), !T, !IO),

    check_rhs("a `call` block mixes kwarg lines and continuations",
        "    call svc\n        a: 1\n        on r.ok:\n"
            ++ "            log info \"b\"\n        b: 2\n",
        ( pred(R::in) is semidet :-
            R ^ rr_actions = [A],
            A ^ ac_block = ab_call([_, _], [_])
        ), !T, !IO),

    % [LGRA.10.8], [LCCO.2.1]: continuations are `call`'s alone; the refusal
    % names the head.
    check_parse_error("only `call` takes a continuation block",
        rule_with_body("    log info \"a\"\n        on x:\n"
            ++ "            log info \"b\"\n"),
        pe_action_block("log"), !T, !IO),

    % An `after` with no block fails at the indent: a whitespace-only line is
    % blank ([LLEX.5.1]), so a block that opened has content.
    check_parse_fails("[LTAC.2.1] an `after` with no block is refused",
        rule_with_body("    log info \"a\"\n    after 30_s:\n"), !T, !IO),

    % ── through `build` ─────────────────────────────────────────────────────

    check_built("the rule body survives `build`",
        rule_with_body("    let x = 1\n    log info \"a\"\n"
            ++ "    after 30_s:\n        log info \"b\"\n"),
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_rule(R)],
            R ^ ar_rhs ^ arr_lets = [_],
            R ^ ar_rhs ^ arr_actions = [_],
            R ^ ar_rhs ^ arr_afters = [_]
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% Expressions -- [LGRA.9.3.1] through [LGRA.9.7.1]
%-----------------------------------------------------------------------------%
%
% Each case asserts the tree's shape, which is what precedence decides.
% Reached through a pattern's `where` ([LGRA.8.1]), through the real front
% end.

    % The expression in `where <src>` of a one-pattern rule.
    %
:- func where_expr(file) = lgra_9_3_1_expr.
:- mode where_expr(in) = out is semidet.

where_expr(F) = E :-
    one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
    B ^ pb_where = yes(E).

:- pred check_expr(string, string, pred(lgra_9_3_1_expr), tally, tally,
                   io, io).
:- mode check_expr(in, in, pred(in) is semidet, in, out, di, uo) is det.

check_expr(Name, Src, Wanted, !T, !IO) :-
    ( if
        front(rule_around("Graph where " ++ Src), F),
        E = where_expr(F),
        Wanted(E)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_expr(tally::in, tally::out, io::di, io::uo) is det.

test_expr(!T, !IO) :-
    % ── primaries [LGRA.9.7.1] ──────────────────────────────────────────────

    check_expr("[LGRA.9.7.1] an integer literal", "1",
        ( pred(E::in) is semidet :- E = ex_int(1i64, _) ), !T, !IO),

    check_expr("[LGRA.9.7.1] a string literal", "\"hi\"",
        ( pred(E::in) is semidet :- E = ex_string("hi", _) ), !T, !IO),

    check_expr("[LGRA.9.7.1] a unit literal is a primary", "30_s",
        ( pred(E::in) is semidet :- E = ex_unit("30", "_s", _) ), !T, !IO),

    % `true` / `false` / `null` arrive as `name` and the parser classifies
    % them ([LLEX.17.6]).
    check_expr("[LGRA.9.7.1] `true` is a boolean literal, not a name", "true",
        ( pred(E::in) is semidet :- E = ex_bool(yes, _) ), !T, !IO),

    check_expr("a bare name is a name", "x",
        ( pred(E::in) is semidet :- E = ex_name(ident("x", _)) ), !T, !IO),

    % ── precedence ──────────────────────────────────────────────────────────

    % [LGRA.9.5.1]: multiplicative binds tighter than additive.
    check_expr("[LGRA.9.5.1] `*` binds tighter than `+`", "a + b * c",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_add, _, ex_binary(bo_mul, _, _, _), _)
        ), !T, !IO),

    check_expr("[LGRA.9.5.1] `+` is left-associative", "a + b + c",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_add, ex_binary(bo_add, _, _, _), _, _)
        ), !T, !IO),

    % `exponent ::= unary ('**' exponent)?`: right-associative, unlike every
    % other binary level.
    check_expr("[LGRA.9.5.1] `**` is right-associative", "a ** b ** c",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_pow, _, ex_binary(bo_pow, _, _, _), _)
        ), !T, !IO),

    check_expr("[LGRA.9.7.1] parentheses regroup", "(a + b) * c",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_mul, ex_binary(bo_add, _, _, _), _, _)
        ), !T, !IO),

    % [LGRA.9.3.1]: `and` binds tighter than `or`.
    check_expr("[LGRA.9.3.1] `and` binds tighter than `or`", "a or b and c",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_or, _, ex_binary(bo_and, _, _, _), _)
        ), !T, !IO),

    % [LGRA.9.5.1]: `not` is logical, at `not_expr`, so `not a == b` is
    % `not (a == b)`.
    check_expr("[LGRA.9.5.1] `not` is logical and outranks comparison",
        "not a == b",
        ( pred(E::in) is semidet :- E = ex_not(ex_compare(_, _, _), _) ),
        !T, !IO),

    check_expr("[LGRA.9.5.1] unary minus is arithmetic", "-a + b",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_add, ex_unary(uo_neg, _, _), _, _)
        ), !T, !IO),

    % [LGRA.9.4.1]: comparison is above bitwise_or, so `==` takes `a | b` on
    % its left.
    check_expr("[LGRA.9.4.1] bitwise binds tighter than comparison",
        "a | b == c",
        ( pred(E::in) is semidet :-
            E = ex_compare(ex_binary(bo_bitor, _, _, _), [_], _)
        ), !T, !IO),

    % ── comparison chains [LGRA.9.3.2] ──────────────────────────────────────

    % [LGRA.9.3.2]: `a < b < c` is `(a < b) and (b < c)`, kept as a chain for
    % the lowering.
    check_expr("[LGRA.9.3.2] comparisons chain rather than nest", "a < b < c",
        ( pred(E::in) is semidet :-
            E = ex_compare(_, [S1, S2], _),
            S1 ^ cs_op = co_lt,
            S2 ^ cs_op = co_lt
        ), !T, !IO),

    check_expr("[LGRA.9.3.2] operators may be mixed in one chain", "a < b == c",
        ( pred(E::in) is semidet :-
            E = ex_compare(_, [S1, S2], _),
            S1 ^ cs_op = co_lt,
            S2 ^ cs_op = co_eq
        ), !T, !IO),

    % ── postfix [LGRA.9.6.1] ────────────────────────────────────────────────

    check_expr("[LGRA.9.6.1] slot access is a postfix", "m.intensity",
        ( pred(E::in) is semidet :-
            E = ex_slot(ex_name(ident("m", _)), ident("intensity", _), _)
        ), !T, !IO),

    % [LGRA.9.7.1]: a call is a postfix: the name `len`, then `(...)`.
    check_expr("[LGRA.9.7.1] a call is a postfix on a name", "len(x)",
        ( pred(E::in) is semidet :-
            E = ex_call(ex_name(ident("len", _)), [_], _)
        ), !T, !IO),

    check_expr("[LGRA.9.6.1] a call may take no arguments", "now()",
        ( pred(E::in) is semidet :- E = ex_call(_, [], _) ), !T, !IO),

    check_expr("[LGRA.9.6.1] postfixes chain left to right", "a.b[0].c",
        ( pred(E::in) is semidet :-
            E = ex_slot(ex_index(ex_slot(_, _, _), _, _), _, _)
        ), !T, !IO),

    % [LGRA.9.6.1]: `'::' TYPE_SYM NULLABLE?`. [LLEX.10.8.5]: `??` out-munches
    % `?`, so the fallible form is spaced, `x::Int? ?? d`.
    check_expr("[LGRA.9.6.1] a cast is a postfix", "x::Int",
        ( pred(E::in) is semidet :-
            E = ex_cast(_, ident("Int", _), non_null, _)
        ), !T, !IO),

    check_expr("[LLEX.10.8.5] `x::Int??d` is `(x::Int) ?? d`", "x::Int??d",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_coalesce, ex_cast(_, _, non_null, _), _, _)
        ), !T, !IO),

    check_expr("[LLEX.10.8.5] `x::Int? ?? d` keeps the nullable",
        "x::Int? ?? d",
        ( pred(E::in) is semidet :-
            E = ex_binary(bo_coalesce, ex_cast(_, _, nullable, _), _, _)
        ), !T, !IO),

    % ── the levels outside [LGRA.9.3.1]'s chain ─────────────────────────────

    check_expr("`??` coalesces", "a ?? b",
        ( pred(E::in) is semidet :- E = ex_binary(bo_coalesce, _, _, _) ),
        !T, !IO),

    check_expr("`in` is an interval relation", "a in b",
        ( pred(E::in) is semidet :- E = ex_binary(bo_in, _, _, _) ),
        !T, !IO),

    check_expr("`..` builds an interval", "1 .. 10",
        ( pred(E::in) is semidet :- E = ex_binary(bo_interval, _, _, _) ),
        !T, !IO),

    check_expr("`is null` is a test", "x is null",
        ( pred(E::in) is semidet :-
            E = ex_is(_, is_positive, is_null, _)
        ), !T, !IO),

    check_expr("`is not` negates the test", "x is not null",
        ( pred(E::in) is semidet :-
            E = ex_is(_, is_negated, is_null, _)
        ), !T, !IO),

    check_expr("[LGRA.9.3.3] `is Int` is a tag test", "x is Int",
        ( pred(E::in) is semidet :-
            E = ex_is(_, is_positive, is_tag(ident("Int", _)), _)
        ), !T, !IO),

    % [LGRA.9.3.3]: `x is Blah` is a parse error, and so is `x is Time`: no
    % tag carries `Time` ([LNUL.4.9]).
    check_parse_fails("[LGRA.9.3.3] `x is Blah` is a parse error",
        "schema S scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    S s where s.v is Blah\n->\n    log info \"x\"\n", !T, !IO),

    check_parse_fails("[LGRA.9.3.3] `Time` is a type, not a tag",
        "schema S scope logical:\n    v: Int key\n\nrule r:\n"
            ++ "    S s where s.v is Time\n->\n    log info \"x\"\n", !T, !IO),

    % ── the boundary, and what happens past it ──────────────────────────────

    % The expression consumes its whole span; leftover tokens are an error.
    check_parse_fails("a `where` with trailing junk is refused",
        rule_around("Graph where a b"), !T, !IO),

    check_parse_fails("a bare `where` with no expression is refused",
        rule_around("Graph where"), !T, !IO),

    % [LGRA.8.3.5]'s multi-line form arrives as one span ([LLEX.7.3]).
    check_parse("[LGRA.8.3.5] a multi-line `where` is one expression",
        "rule r:\n    Graph g where (\n        g.a == 1\n"
            ++ "        and g.b == 2\n    )\n->\n    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            E = where_expr(F),
            E = ex_binary(bo_and, _, _, _)
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% Rules -- [LGRA.6.1], [LGRA.8.1]
%-----------------------------------------------------------------------------%

:- func one_rule(file) = lgra_6_1_rule_decl.
:- mode one_rule(in) = out is semidet.

one_rule(file(_, [td_rule(R)])) = R.

    % A minimal rule around `Lhs`, so the pattern cases carry no scaffolding.
    %
:- func rule_around(string) = string.

rule_around(Lhs) = "rule r:\n    " ++ Lhs ++ "\n->\n    log info \"x\"\n".

:- pred test_rule(tally::in, tally::out, io::di, io::uo) is det.

test_rule(!T, !IO) :-
    % ── the declaration ─────────────────────────────────────────────────────

    check_parse("[LGRA.6.1] a rule parses to a name, one pattern and a body",
        rule_around("Motion m"),
        ( pred(F::in) is semidet :-
            R = one_rule(F),
            R ^ rd_name ^ id_name = "r",
            R ^ rd_lhs = [lc_pattern(pat_simple(_))],
            R ^ rd_rhs ^ rr_actions = [_]
        ), !T, !IO),

    % [LGRA.6.5]: a bare string as the body's first line is the docstring.
    check_parse("[LGRA.6.5] the first string in the LHS block is the docstring",
        "rule r:\n    \"why this fires\"\n    Motion m\n->\n    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            R = one_rule(F),
            R ^ rd_doc = yes("why this fires"),
            R ^ rd_lhs = [_]
        ), !T, !IO),

    % [LGRA.6.6.1]: zero or more rate mods; `cooldown` is the only one.
    check_parse("[LGRA.6.6.1] a `cooldown` in the header",
        "rule r cooldown 5_min:\n    Motion m\n->\n    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_modifiers = [rm_cooldown(_, _)]
        ), !T, !IO),

    % [LCDB.5.1]: `debounce` is not in the grammar.
    check_parse_fails("[LCDB.5.1] `debounce` is not a rate modifier",
        "rule r debounce 2_s:\n    Motion m\n->\n    log info \"x\"\n",
        !T, !IO),

    % [LGRA.6.1]'s `rate_key`: a cooldown's duration stops at `by`, the paths
    % are kept in the order written, and the header's own `:` follows them.
    check_parse("[LGRA.6.1] `by:` paths, after a cooldown, before the colon",
        "rule r cooldown 5_min by: m.who, m.zone:\n    Motion m\n->\n"
            ++ "    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_modifiers = [rm_cooldown([_], _),
                rm_by(rk_paths([key_path(B1, S1), key_path(B2, S2)]), _)],
            B1 ^ id_name = "m", S1 ^ id_name = "who",
            B2 ^ id_name = "m", S2 ^ id_name = "zone"
        ), !T, !IO),

    check_parse("[LGRA.6.1] `by: none`, before a cooldown",
        "rule r by: none cooldown 2_s:\n    Motion m\n->\n    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_modifiers = [rm_by(rk_none, _),
                rm_cooldown(_, _)]
        ), !T, !IO),

    % `cooldown` is reserved ([LLEX.9.6]), and `validate` refuses the slot
    % ([LLEX.9.7]); the parser takes it.
    check_parse("a slot named `cooldown` parses (validate refuses it)",
        "schema S:\n    cooldown: Int\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_fields = [Fld],
            Fld ^ fd_name ^ id_name = "cooldown"
        ), !T, !IO),

    % [LGRA.6.1]: `pattern+`, so an LHS of docstring alone is a grammar error.
    check_parse_error("[LGRA.6.1] a rule with no patterns is a parse error",
        "rule r:\n    \"only a docstring\"\n->\n    log info \"x\"\n",
        pe_empty_lhs("r"), !T, !IO),

    % ── the pattern body [LGRA.8.1] ─────────────────────────────────────────

    % [LGRA.8.6]: the binding is optional.
    check_parse("[LGRA.8.6] a pattern binding is optional",
        rule_around("Graph"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_binding = no,
            B ^ pb_type = tr_bare(ident("Graph", _))
        ), !T, !IO),

    check_parse("[LGRA.8.1] a bound pattern keeps its binding",
        rule_around("Motion m"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_binding = yes(ident("m", _))
        ), !T, !IO),

    % [LGRA.8.6]: a `where` needs no binding; it may read constants or an
    % earlier pattern's binding.
    check_parse("[LGRA.8.6] a `where` needs no binding of its own",
        rule_around("Graph where 1 > 0"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_binding = no,
            B ^ pb_where = yes(_)
        ), !T, !IO),

    % [LGRA.8.3.3]: `within` is pattern-level, after the binding, and never
    % inside a `where` -- so both may appear and `within` is taken first.
    check_parse("[LGRA.8.3.3] `within` and `where` both, in that order",
        rule_around("Motion m within 5_s where m.intensity > 0.5"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_within = yes([_ | _]),
            B ^ pb_where = yes(_)
        ), !T, !IO),

    % `where` and `within` are reserved ([LLEX.9.6]), so neither is read as a
    % binding ([LGRA.8.6]).
    check_parse("[LGRA.8.6] `within` is not read as a binding",
        rule_around("TempReading within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_binding = no,
            B ^ pb_within = yes([_ | _])
        ), !T, !IO),

    % [LGRA.8.1]: `type_ref ::= NAME ('.' NAME)*`. A type position
    % holds no binding, so the `.` cannot be slot access: the last name is the
    % schema and the rest the library path ([LGRA.22.4]).
    check_parse("[LGRA.8.1] a `lib.Schema` qualified head parses",
        rule_around("weather.Forecast f"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_type = tr_qualified([ident("weather", _)],
                                       ident("Forecast", _))
        ), !T, !IO),

    check_parse("[LGRA.8.1] a dotted library path qualifies too",
        rule_around("units.currency.Dollar d"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_simple(B))],
            B ^ pb_type = tr_qualified([ident("units", _),
                ident("currency", _)], ident("Dollar", _))
        ), !T, !IO),

    % ── negation [LGRA.8.4] ─────────────────────────────────────────────────

    check_parse("[LGRA.8.4.1] `no P` negates without parens",
        rule_around("no Motion m within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_negated(_, np_bare, _))]
        ), !T, !IO),

    % [LGRA.8.4.2]: parens are optional around a simple body; which was
    % written is recorded.
    check_parse("[LGRA.8.4.2] `no (P)` is the parenthesised form",
        rule_around("no (Sensor t where t.state > 90)"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs =
                [lc_pattern(pat_negated(_, np_parenthesised, _))]
        ), !T, !IO),

    % [LGRA.8.6] again: `no Graph` is well-formed, binding and all omitted.
    check_parse("[LGRA.8.6] `no Graph` needs no binding either",
        rule_around("no Graph"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_negated(B, np_bare, _))],
            B ^ pb_binding = no
        ), !T, !IO),

    % ── sequences [LGRA.8.5] ────────────────────────────────────────────────

    check_parse("[LGRA.8.5.2] a `then` chain is one sequence pattern",
        rule_around("DoorOpen d then Motion m within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(sl_plain, _, [_], _)
        ), !T, !IO),

    % [LGRA.8.5.8]: chains left to right, each `within` scoping the `then`
    % before it.
    check_parse("[LGRA.8.5.8] a two-step chain keeps both steps",
        rule_around("DoorUnlock u then DoorOpen d within 10_s "
            ++ "then Motion m within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [_, _], _)
        ), !T, !IO),

    % [LGRA.8.5.10]: a trailing `where` is the last step's; there is no
    % sequence-wide one.
    check_parse("[LGRA.8.5.10] a trailing `where` is the last step's",
        rule_around("DoorOpen d then Motion m within 30_s "
            ++ "where d.location == m.location"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [Step], _),
            Step ^ ts_body ^ pb_where = yes(_)
        ), !T, !IO),

    check_parse("[LGRA.8.5.10] on a two-step chain, only the last step's",
        rule_around("A a then B b within 5_s then C c within 10_s "
            ++ "where c.v > a.v"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [S1, S2], _),
            S1 ^ ts_body ^ pb_where = no,
            S2 ^ ts_body ^ pb_where = yes(_)
        ), !T, !IO),

    check_parse("[LGRA.8.5.10] a trailing `where`'s captures are the step's",
        rule_around("A a then B b within 5_s where (x) = b.s ~ /(.)/"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [Step], _),
            Step ^ ts_body ^ pb_capture = yes(_)
        ), !T, !IO),

    % [LGRA.8.5.14] / [LGRA.8.5.16]: `latest` pins the first pattern only, so
    % it is the sequence's, not a step's.
    check_parse("[LGRA.8.5.16] `latest` modifies only the first pattern",
        rule_around("latest DoorOpen d then Motion m within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(sl_latest, _, [_], _)
        ), !T, !IO),

    % `latest` is the prefix only when a NAME follows. A lone `latest X x`
    % stands.
    check_parse("a lone `latest X` parses as a sequence with no steps",
        rule_around("latest DoorOpen d"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_sequence(sl_latest, _, [],
                _))]
        ), !T, !IO),

    % [LGRA.8.5.7]: `within T` is required on every `then`.
    check_parse_fails("[LGRA.8.5.7] a `then` with no `within` is refused",
        rule_around("DoorOpen d then Motion m"), !T, !IO),

    % The line-leading layout ([LGRA.8.1], [LTHE.4.1]): `then` opens its
    % own line and folds into the pattern above.
    check_parse("[LGRA.8.5.2] a `then` line folds into the pattern above it",
        rule_around("DoorOpen d\n    then Motion m within 30_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(sl_plain, _, [_], _)
        ), !T, !IO),

    check_parse("[LGRA.8.5.8] two `then` lines are two steps of one sequence",
        rule_around("A a\n    then B b within 5_s\n    then C c within 10_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [_, _], _)
        ), !T, !IO),

    % A `where` after a `then` line's `within` is the step's.
    check_parse("[LGRA.8.5.2] a `where` on a `then` line is the step's",
        rule_around("A a\n    then B b within 5_s where b.v == 1"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(_, _, [Step], _),
            Step ^ ts_body ^ pb_where = yes(_)
        ), !T, !IO),

    % [LGRA.8.1]'s `then_step ::= 'then' 'latest'? type_ref binding? 'within'
    % time_expr where_clause?`: a step's `where` follows its `within`, in
    % either layout.
    check_parse_fails("[LGRA.8.1] a step's `where` before its `within`",
        rule_around("A a then B b where b.v > 0 within 5_s"), !T, !IO),
    check_parse_fails("[LGRA.8.5.10] a last step's `where` and a trailing one",
        rule_around("A a then B b where b.v > 0 within 5_s where b.v < 9"),
        !T, !IO),
    check_parse_fails("[LGRA.8.5.10] the same on a `then` line",
        rule_around("A a\n    then B b where b.v > 0 within 5_s "
            ++ "where b.v < 9"),
        !T, !IO),

    check_parse("[LGRA.8.5.16] `latest` on its own line takes the `then` below",
        rule_around("latest A a\n    then B b within 5_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(sl_latest, _, [_], _)
        ), !T, !IO),

    check_parse("a `latest` line with no `then` below stays its own pattern",
        rule_around("latest A a\n    B b"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_sequence(sl_latest, _, [],
                _)), lc_pattern(pat_simple(_))]
        ), !T, !IO),

    % Nothing positive above: kept as its own clause, for `validate` to name.
    check_parse("[LTHE.4.9] a `then` line under a `no` is not folded",
        rule_around("no A a\n    then B b within 5_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(pat_negated(_, _, _)),
                lc_then(_)]
        ), !T, !IO),

    check_parse("[LTHE.5.4] `then latest` is parsed, for validate to refuse",
        rule_around("A a\n    then latest B b within 5_s"),
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs = [lc_pattern(P)],
            P = pat_sequence(sl_plain, _, [Step], _),
            Step ^ ts_latest = sl_latest
        ), !T, !IO),

    check_parse_fails("[LGRA.8.5.7] a `then` line with no `within` is refused",
        rule_around("A a\n    then B b"), !T, !IO),

    % ── the LHS clause set ──────────────────────────────────────────────────

    % There is no `hold` clause: `hold` reads as a schema name, and the `by`
    % after it is a parse error.
    check_parse_fails("a `hold ... by ...` line is not an LHS clause",
        "rule r:\n    Trig t\n    hold Lock by k = t.k\n->\n    log info \"x\"\n",
        !T, !IO),

    check_parse("several patterns make several LHS clauses",
        "rule r:\n    Motion m\n    no Light l\n->\n    log info \"x\"\n",
        ( pred(F::in) is semidet :-
            one_rule(F) ^ rd_lhs =
                [lc_pattern(pat_simple(_)), lc_pattern(pat_negated(_, _, _))]
        ), !T, !IO),

    % ── through `build` ─────────────────────────────────────────────────────

    % `no (P)` and `no P` become one node ([LGRA.8.4.2]).
    check_built("[LGRA.8.4.2] `build` drops the negation's parentheses",
        rule_around("no (Graph)"),
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_rule(R)],
            R ^ ar_lhs = [alc_pattern(ap_negated(_, _))]
        ), !T, !IO),

    check_built("a rule survives `build` with its name and patterns",
        rule_around("Motion m"),
        ( pred(F::in) is semidet :-
            F ^ af_decls = [ad_rule(R)],
            R ^ ar_name ^ id_name = "r",
            R ^ ar_lhs = [alc_pattern(ap_simple(_))]
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% build -- CST to AST
%-----------------------------------------------------------------------------%
%
% `build` is `det` with no error arm. What it changes is [LSCP.1.4]'s default
% and [LGRA.5.1]'s marker classification.

    % Source all the way to an AST, through the real front end.
    %
:- pred built(string::in, ast_file::out) is semidet.

built(Src, Ast) :-
    front(Src, Cst),
    build_file(Cst, Ast).

:- pred check_built(string, string, pred(ast_file), tally, tally, io, io).
:- mode check_built(in, in, pred(in) is semidet, in, out, di, uo) is det.

check_built(Name, Src, Wanted, !T, !IO) :-
    ( if built(Src, Ast), Wanted(Ast) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- func one_ast_schema(ast_file) = ast_schema.
:- mode one_ast_schema(in) = out is semidet.

one_ast_schema(ast_file(_, [ad_schema(S)])) = S.

    % That `dsc.diag` links. Whether its names are registered codes is
    % `test_registry`'s check.
    %
:- pred test_diag(tally::in, tally::out, io::di, io::uo) is det.

test_diag(!T, !IO) :-
    check("the diagnostic registry links and names its codes",
        ( if ds_validate_name(dv_unknown_slot) = "DS_VALIDATE_UNKNOWN_SLOT"
          then yes else no ), !T, !IO).

:- pred test_build(tally::in, tally::out, io::di, io::uo) is det.

test_build(!T, !IO) :-
    % ── [LSCP.1.4]'s default, and its provenance ────────────────────────────

    % "Bare `schema Foo:` means `scope explicit`", applied here and not in the
    % CST.
    check_built("[LSCP.1.4] a bare schema defaults to `scope explicit`",
        "schema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_lifecycle = al_explicit
        ), !T, !IO),

    % The default is recorded as one, so [LSCP.1.6] and [LSCP.1.7] name only a
    % form the author wrote.
    check_built("[LSCP.1.4] the default is recorded as defaulted",
        "schema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_scope = scope_defaulted
        ), !T, !IO),

    check_built("[LSCP.1.4] a written `scope explicit` is recorded as written",
        "schema S scope explicit:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_lifecycle = al_explicit,
            S ^ as_scope = scope_written
        ), !T, !IO),

    % [LSCP.1.7]: `ambient` modifies a base lifecycle.
    check_built("[LSCP.1.7] `ambient` rides on the base lifecycle",
        "schema S scope logical ambient:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_lifecycle = al_logical(aa_ambient)
        ), !T, !IO),

    check_built("[LSCP.1.5] `scope activation` survives build",
        "schema S scope activation:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_lifecycle = al_activation
        ), !T, !IO),

    % The `ttl` duration is carried through as tokens.
    check_built("`scope ttl` keeps its duration as an unlowered span",
        "schema S scope ttl 30_min:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_lifecycle = al_ttl(Span, aa_not_ambient),
            Span = [_ | _]
        ), !T, !IO),

    % ── [LGRA.5.1]'s markers, classified ────────────────────────────────────

    check_built("[LGRA.5.1] the markers are classified",
        "schema S:\n    a: Int key retained\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_fields = [Fld],
            Fld ^ af_markers = [am_key(_), am_retained(_)]
        ), !T, !IO),

    % Order and duplicates survive, so a validator sees a repeated `key`.
    check_built("[LGRA.5.1] a repeated marker is not collapsed",
        "schema S:\n    a: Int key key\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_fields = [Fld],
            Fld ^ af_markers = [am_key(_), am_key(_)]
        ), !T, !IO),

    % The marker set is grammatical, so an unknown word is a parse error and
    % `ast_marker` has no arm for one.
    check_parse_fails("[LGRA.5.1] an unrecognised marker is a parse error",
        "schema S:\n    a: Int wibble\n", !T, !IO),

    % Markers are classified by position, so a slot named `key` keeps its
    % name. `validate` refuses the name ([LLEX.9.5], [LLEX.9.6]).
    check_built("a slot named `key` marked `key` builds with both intact",
        "schema S:\n    key: String key\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_fields = [Fld],
            Fld ^ af_name ^ id_name = "key",
            Fld ^ af_markers = [am_key(_)]
        ), !T, !IO),

    % ── what passes through ─────────────────────────────────────────────────

    check_built("nullability, type and docstring survive",
        "schema S:\n    a: Float? \"how warm\"\n",
        ( pred(F::in) is semidet :-
            S = one_ast_schema(F),
            S ^ as_fields = [Fld],
            Fld ^ af_type ^ id_name = "Float",
            Fld ^ af_nullable = nullable,
            Fld ^ af_doc = yes("how warm")
        ), !T, !IO),

    % [RLOW.17.1]: a test is built with its name and its sections in source
    % order.
    check_built("[LTSL.2.3] a test declaration is built with its sections",
        "test \"t\":\n    produces:\n        activated r\n",
        ( pred(F::in) is semidet :-
            F = ast_file(_, [ad_test(T)]),
            T ^ tst_name = ex_string("t", _),
            T ^ tst_sections = [tsec_produces([A], _)],
            A ^ tas_never = no,
            A ^ tas_head = thd_activated(ident("r", _))
        ), !T, !IO),

    check_built("[LGRA.3.1] the `use` declaration survives with its settings",
        "use realtime:\n    linear_scan: false\nschema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            F ^ af_use = yes(U),
            U ^ au_base ^ id_name = "realtime",
            U ^ au_settings = [ast_setting(I, no)],
            I ^ id_name = "linear_scan"
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% validate
%-----------------------------------------------------------------------------%

    % Rendering: the caret row, and [RCLI.5.3]'s blank line between
    % diagnostics. The corpus asserts codes, not rendered text ([RCLI.5.2]),
    % so these are the underline's only check.
    %
:- pred test_render(tally::in, tally::out, io::di, io::uo) is det.

test_render(!T, !IO) :-
    Src = "rule kitchen_motion\n    Motion m\n",
    % A span within one line underlines its whole width. Columns are 0-based
    % here and 1-based in the rendered header.
    Spanned = with_end(
        front_error_at(parse_generic, pos(1, 5), "no colon after the name"),
        pos(1, 19)),
    check("render:a span underlines its whole width",
        ( if
            render_diagnostic("example.ds", Src, Spanned) =
                "File \"example.ds\", line 1, column 6\n" ++
                "    rule kitchen_motion\n" ++
                "         ^^^^^^^^^^^^^^\n" ++
                "DS_PARSE_GENERIC: no colon after the name"
        then yes else no ), !T, !IO),

    % A site with no end points with one caret. Line 2 is indented four, so
    % the caret is at the gutter's four plus four.
    Pointed = front_error_at(parse_generic, pos(2, 4), "unexpected"),
    check("render:a site with no end recorded points with one caret",
        ( if
            render_diagnostic("example.ds", Src, Pointed) =
                "File \"example.ds\", line 2, column 5\n" ++
                "        Motion m\n" ++
                "        ^\n" ++
                "DS_PARSE_GENERIC: unexpected"
        then yes else no ), !T, !IO),

    % A zero-width span is floored at one caret.
    Empty = with_end(
        front_error_at(parse_generic, pos(2, 4), "here"), pos(2, 4)),
    check("render:a zero-width span still shows one caret",
        ( if
            render_diagnostic("example.ds", Src, Empty) =
                "File \"example.ds\", line 2, column 5\n" ++
                "        Motion m\n" ++
                "        ^\n" ++
                "DS_PARSE_GENERIC: here"
        then yes else no ), !T, !IO),

    % A span leaving its line is clipped and says where it ends.
    Multi = with_end(
        front_error_at(parse_generic, pos(1, 5), "runs on"), pos(2, 4)),
    check("render:a multi-line span is clipped and says where it ends",
        ( if
            render_diagnostic("example.ds", Src, Multi) =
                "File \"example.ds\", line 1, column 6\n" ++
                "    rule kitchen_motion\n" ++
                "         ^^^^^^^^^^^^^^ (continues to line 2, column 5)\n" ++
                "DS_PARSE_GENERIC: runs on"
        then yes else no ), !T, !IO),

    % A position past the source keeps its header and has no source line.
    Past = front_error_at(parse_generic, pos(9, 0), "at end of file"),
    check("render:a position past the source keeps its header",
        ( if
            render_diagnostic("example.ds", Src, Past) =
                "File \"example.ds\", line 9, column 1\n" ++
                "DS_PARSE_GENERIC: at end of file"
        then yes else no ), !T, !IO),

    % [RCLI.5.3]: a blank line between; no diagnostics is the empty string.
    check("[RCLI.5.3]several diagnostics are blank-line separated",
        ( if
            rcli_5_3_render_all("example.ds", Src, [Pointed, Empty]) =
                render_diagnostic("example.ds", Src, Pointed) ++ "\n\n" ++
                render_diagnostic("example.ds", Src, Empty)
        then yes else no ), !T, !IO),
    check("[RCLI.5.3]no diagnostics renders as nothing",
        ( if rcli_5_3_render_all("example.ds", Src, []) = ""
        then yes else no ), !T, !IO).

    % RE2 itself, through `ds.re2` ([LREG.8.1]).
    %
:- pred test_re2(tally::in, tally::out, io::di, io::uo) is det.

test_re2(!T, !IO) :-
    Plain = re2_flags(no, no, no),
    check("[LREG.3.1] RE2 reports each capturing group, named or positional",
        ( if
            re2_compile("(?<device>\\w+) on (\\d+)(?:x)", Plain)
                = re2_valid([yes("device"), no])
        then yes else no ), !T, !IO),
    check("[LREG.8.3] `(?P<n>...)` names a group as `(?<n>...)` does",
        ( if re2_compile("(?P<code>\\d+)", Plain) = re2_valid([yes("code")])
        then yes else no ), !T, !IO),
    check("[LREG.7.1] an unclosed group is RE2's syntax error",
        ( if re2_compile("(unclosed", Plain) = re2_invalid(_)
        then yes else no ), !T, !IO),
    check("[LREG.8.4] RE2 refuses lookahead on its own",
        ( if re2_compile("error(?=:)", Plain) = re2_invalid(_)
        then yes else no ), !T, !IO),
    check("[LREG.8.4] a class holding `*+` is two members, not a quantifier",
        ( if re2_compile("[*+]", Plain) = re2_valid([])
        then yes else no ), !T, !IO),
    check("[LREG.1.2] a match is partial",
        ( if re2_matches("err", Plain, "an error here") then yes else no ),
        !T, !IO),
    check("[LREG.5.2] `i` folds case",
        ( if
            re2_matches("^err", re2_flags(yes, no, no), "ERROR: x"),
            not re2_matches("^err", Plain, "ERROR: x")
        then yes else no ), !T, !IO),
    check("[LREG.5.2] `m` anchors at line boundaries",
        ( if
            re2_matches("^b", re2_flags(no, yes, no), "a\nb"),
            not re2_matches("^b", Plain, "a\nb")
        then yes else no ), !T, !IO),
    check("[LREG.5.2] `s` lets `.` match a newline",
        ( if
            re2_matches("a.b", re2_flags(no, no, yes), "a\nb"),
            not re2_matches("a.b", Plain, "a\nb")
        then yes else no ), !T, !IO),
    % RE2's refusal text, which [LREG.8.4]'s diagnostic reads.
    re2_refusal("error(?=:)", LookMsg),
    check("[LREG.8.4] RE2 refuses a lookahead as: " ++ LookMsg,
        ( if string.prefix(LookMsg, "invalid perl operator: (?=")
        then yes else no ), !T, !IO),
    re2_refusal("^(\\w+)\\1", BackMsg),
    check("[LREG.8.4] RE2 refuses a backreference as: " ++ BackMsg,
        ( if string.prefix(BackMsg, "invalid escape sequence: \\1")
        then yes else no ), !T, !IO),
    re2_refusal("a*+", PossMsg),
    check("[LREG.8.4] RE2 refuses a possessive quantifier as: " ++ PossMsg,
        ( if PossMsg = "bad repetition operator: *+" then yes else no ),
        !T, !IO).

:- pred re2_refusal(string::in, string::out) is det.

re2_refusal(Pattern, Message) :-
    ( if re2_compile(Pattern, re2_flags(no, no, no)) = re2_invalid(M) then
        Message = M
    else
        Message = "(accepted)"
    ).

    % The regex front end -- [LREG.6] lexing, [LGRA.9.3.1]'s `match_expr`, and
    % the [LREG.2] - [LREG.8] checks.
    %
:- func regex_source(string) = string.

regex_source(Rule) =
    "schema Log scope logical:\n    k: Int key\n    msg: String mutable\n"
    ++ "    num: Int mutable\n    raw: Bytes mutable\n\nrule r:\n" ++ Rule.

    % Intervals and null literals -- [LINT], [LNUL.4.4].
    %
:- func interval_source(string) = string.

interval_source(Rule) =
    "schema W scope logical:\n    k: Int key\n    lo: Int mutable\n"
    ++ "    hi: Int mutable\n    t0: Time mutable\n    t1: Time mutable\n"
    ++ "    d0: Date mutable\n    v: Float? mutable\n    b0: Bool mutable\n"
    ++ "    b1: Bool mutable\n    raw: Bytes mutable\n\nrule r:\n" ++ Rule
    ++ "->\n    log info \"x\"\n".

    % Two `Reading`s bound `a` and `b`, the given `let`s, and the given
    % expression as an emit's `Bool` slot value -- the one place a `let` is
    % read. LEXP.7.20.
    %
:- func fact_ref_let_source(string, string) = string.

fact_ref_let_source(Lets, Expr) =
    "schema Reading scope logical:\n    id: String key\n    v: Int mutable\n\n"
    ++ "schema Before scope logical:\n    id: String key\n"
    ++ "    earlier: Bool mutable\n\n"
    ++ "rule r:\n    Reading a\n    Reading b\n->\n    " ++ Lets
    ++ "    emit Before logical id: a.id earlier: " ++ Expr ++ "\n".

:- pred test_intervals(tally::in, tally::out, io::di, io::uo) is det.

test_intervals(!T, !IO) :-
    check_validated("[LINT.3.1.1] an Int point in an Int interval",
        interval_source("    W w where w.k in (w.lo .. w.hi)\n"), !T, !IO),
    check_validated("[LINT.6.1] `start` and `duration` read off an interval",
        interval_source("    W w where (w.t0 .. w.t1).start == w.t0 "
            ++ "and (w.t0 .. w.t1).duration > 1_s\n"), !T, !IO),
    check_validated("[LINT.4.1] two Int intervals overlap",
        interval_source("    W w where (w.lo .. w.hi) overlaps (w.k .. w.hi)\n"),
        !T, !IO),
    % [LEXP.7.12.5]: a `Float` slot in a string comparison is a compile error,
    % with no code of its own: DS_VALIDATE_TYPE_MISMATCH.
    check_validate_error("[LEXP.7.12.5] a Float slot against a string literal",
        "schema S scope logical:\n    k: String key\n    f: Float mutable\n\n"
            ++ "rule r:\n    S s where s.f == \"x\"\n->\n    log info \"m\"\n",
        dv_type_mismatch, !T, !IO),

    % LEXP.7.20 with [LLET.12.5]: a `let` bound to a pattern binding IS that
    % binding, so an ordering on it is refused, through a chain of such `let`s.
    % A `let` bound to a slot still orders. Exactly that code: a conformance
    % `compile_error` passes when its code is among others.
    check_validate_codes("[LLET.12.5] an ordering through a `let`, and only it",
        fact_ref_let_source("let x = a\n", "x < b"),
        [dv_unordered_type], !T, !IO),
    check_validate_codes("[LLET.12.5] an ordering through two `let`s",
        fact_ref_let_source("let x = a\n    let y = x\n", "y < b"),
        [dv_unordered_type], !T, !IO),
    check_validated("[LLET.12.5] a `let` bound to a slot still orders",
        fact_ref_let_source("let x = a.v\n", "x < b.v"), !T, !IO),

    check_validate_error("[LINT.2.2] a Date joined to a Time",
        interval_source("    W w where w.t0 in (w.d0 .. w.t1)\n"),
        dv_interval_mixed_operands, !T, !IO),
    % [LINT.2.2]: "The compiler must refuse ... an operand of a type
    % [LINT.1.1] does not list -- a `Bool`, a `Bytes` value, a whole `Json`
    % value or a fact reference -- with `DS_VALIDATE_UNORDERED_TYPE`."
    %
    % Exactly that code: the refused interval reaches `in` as an error, and a
    % `Bool` joined to an `Int` is not also a mixed pair.
    check_validate_codes("[LINT.2.2] an interval over Bool",
        interval_source("    W w where w.b0 in (w.b0 .. w.b1)\n"),
        [dv_unordered_type], !T, !IO),
    check_validate_codes("[LINT.2.2] an interval over Bytes",
        interval_source("    W w where w.raw in (w.raw .. w.raw)\n"),
        [dv_unordered_type], !T, !IO),
    check_validate_codes("[LINT.2.2] an interval over a fact reference",
        interval_source("    W w where w in (w .. w)\n"),
        [dv_unordered_type], !T, !IO),
    check_validate_codes("[LINT.2.2] a Bool endpoint against an Int one",
        interval_source("    W w where w.k in (w.lo .. w.b0)\n"),
        [dv_unordered_type], !T, !IO),
    % [LINT.6.1]: "The compiler must refuse ... `i.duration` on an interval
    % whose element type is neither `Time` nor `Date`, with
    % `DS_VALIDATE_BAD_INTERVAL_COMPONENT`." The `Date` interval is the
    % control: `duration` stays a `Duration` there ([LINT.6.2]).
    check_validate_codes("[LINT.6.1] `duration` of an Int interval",
        interval_source("    W w where (w.lo .. w.hi).duration > 1_s\n"),
        [dv_bad_interval_component], !T, !IO),
    check_validated("[LINT.6.2] `duration` of a Date interval",
        interval_source("    W w where (w.d0 .. w.d0).duration > 1_s\n"),
        !T, !IO),
    check_validate_error("[LINT.3.1.3] a Time point in an Int interval",
        interval_source("    W w where w.t0 in (w.lo .. w.hi)\n"),
        dv_type_mismatch, !T, !IO),
    check_validate_error("[LINT.4.5] `contains` a literal",
        interval_source("    W w where (w.lo .. w.hi) contains 42\n"),
        dv_interval_rel_non_interval, !T, !IO),
    check_validate_error("[LINT.4.2] Int intervals overlapping Time ones",
        interval_source("    W w where (w.lo .. w.hi) overlaps (w.t0 .. w.t1)\n"),
        dv_type_mismatch, !T, !IO),
    check_validate_error("[LINT.5.3] intervals have no ordering",
        interval_source("    W w where (w.lo .. w.hi) < (w.lo .. w.hi)\n"),
        dv_interval_no_ordering, !T, !IO),
    check_validate_error("[LINT.5.4] interval equality across element types",
        interval_source("    W w where (w.lo .. w.hi) == (w.t0 .. w.t1)\n"),
        dv_type_mismatch, !T, !IO),
    check_validate_error("[LINT.6.1] an interval has no `midpoint`",
        interval_source("    W w where (w.t0 .. w.t1).midpoint == w.t0\n"),
        dv_bad_interval_component, !T, !IO),
    check_validate_error("[LINT.7.4] literal endpoints in the wrong order",
        interval_source("    W w where w.k in (5 .. 3)\n"),
        dv_interval_inverted, !T, !IO),
    check_validate_error("[LNUL.4.4] `== null` on the right",
        interval_source("    W w where w.v == null\n"),
        dv_null_literal_comparison, !T, !IO),
    check_validate_error("[LNUL.4.4] `null !=` on the left",
        interval_source("    W w where null != w.v\n"),
        dv_null_literal_comparison, !T, !IO),
    check_validated("[LNUL.4.4] `is null` is the test that stays",
        interval_source("    W w where w.v is null\n"), !T, !IO).

    % `let` order -- [LLET.12.3], [LLET.10.6].
    %
:- func let_order_source(string) = string.

let_order_source(Lets) =
    "schema T scope logical:\n    k: Int key\n\nrule r:\n    T t\n->\n" ++ Lets
    ++ "    log info \"{a}\"\n".

    % Interpolation positions and format specs -- [LGRA.2.9.6.5],
    % [LGRA.2.9.6.8], [LUNI.11.2].
    %
:- func interp_source(string) = string.

interp_source(Body) =
    "schema T scope logical:\n    k: Int key\n    name: String mutable\n\n"
    ++ "rule r:\n" ++ Body.

:- pred test_interp_specs(tally::in, tally::out, io::di, io::uo) is det.

test_interp_specs(!T, !IO) :-
    check_validated("[LGRA.2.9.6.5] the corpus's own numeric specs",
        interp_source("    T t\n->\n    log info \"{t.k:+10d} {t.k:08d} "
            ++ "{t.k:>4x} {t.name:s}\"\n"), !T, !IO),
    check_validate_error("[LGRA.2.9.6.5] precision on `d`",
        interp_source("    T t\n->\n    log info \"{t.k:.2d}\"\n"),
        dv_interp_bad_format, !T, !IO),
    check_validate_error("[LGRA.2.9.6.5] zero-pad with left-align",
        interp_source("    T t\n->\n    log info \"{t.k:0<4d}\"\n"),
        dv_interp_bad_format, !T, !IO),
    check_validate_error("[LGRA.2.9.6.5] a spec outside the grammar",
        interp_source("    T t\n->\n    log info \"{t.k:.2_d}\"\n"),
        dv_interp_bad_format, !T, !IO),
    % A width or precision is the wire's `uint32` on every host; both sides
    % of the bound.
    check_validated("a width of 4294967295, the uint32 maximum, is admitted",
        interp_source("    T t\n->\n    log info \"{t.k:4294967295d}\"\n"),
        !T, !IO),
    check_validate_error("a width of 4294967296, one past uint32, is refused",
        interp_source("    T t\n->\n    log info \"{t.k:4294967296d}\"\n"),
        dv_interp_bad_format, !T, !IO),
    check_validated("a precision of 4294967295 on `s` is admitted",
        interp_source("    T t\n->\n    log info \"{t.name:.4294967295s}\"\n"),
        !T, !IO),
    check_validate_error("a precision of 4294967296 on `s` is refused",
        interp_source("    T t\n->\n    log info \"{t.name:.4294967296s}\"\n"),
        dv_interp_bad_format, !T, !IO),
    check_validate_error("[LUNI.11.2] `:u` on a value with no unit",
        interp_source("    T t\n->\n    log info \"{t.k:u}\"\n"),
        dv_interp_unit_non_unit, !T, !IO),
    % There is no `U`: it fails the grammar.
    check_validate_error("[LUNI.11.2] `:U` is not a type",
        interp_source("    T t\n->\n    log info \"{t.k:U}\"\n"),
        dv_interp_bad_format, !T, !IO),
    check_validate_error("[LGRA.2.9.6.8] a `{path}` in a `where` string",
        interp_source("    T t where t.name == \"m-{t.name}\"\n->\n"
            ++ "    log info \"x\"\n"),
        dv_interp_inert_position, !T, !IO),
    check_validated("[LGRA.2.9.6.7] `{{` stays literal in a `where` string",
        interp_source("    T t where t.name == \"m-{{t.name}}\"\n->\n"
            ++ "    log info \"x\"\n"), !T, !IO).

    % Constants -- [LGRA.4.1], [LGRA.13.3].
    %
:- func const_source(string) = string.

const_source(Consts) = Consts ++ "\nschema S scope logical:\n    k: Int key\n".

    % Continuation predicates against a response schema -- [LCCO.11.1].
    %
:- func response_source(string) = string.

response_source(Predicate) =
    "schema T scope logical:\n    k: Int key\n\n"
    ++ "schema Resp scope ttl 1_min:\n    corr: String\n    code: Int\n\n"
    ++ "service svc.get:\n    kwarg id: String\n    response Resp\n\n"
    ++ "rule r:\n    T t\n->\n    call svc.get id: \"x\" nocooldown\n"
    ++ "        on " ++ Predicate ++ ":\n            log info \"{t.k}\"\n".

:- pred test_response_fields(tally::in, tally::out, io::di, io::uo) is det.

test_response_fields(!T, !IO) :-
    check_validated("[LCCO.11.1] a continuation reads a response slot",
        response_source("response.code == 200"), !T, !IO),
    check_validate_error("[LCCO.11.1] a continuation reads no such slot",
        response_source("response.nope > 0"),
        dv_unknown_slot, !T, !IO).

    % Unit declarations -- [LUNI.4.3], [LUNI.4.5], [LUNI.4.6].
    %
:- func currency_units = string.

currency_units =
    "unit dimension currency_usd storage int64 base USD_cent\n"
    ++ "unit USD_cent: currency_usd\n"
    ++ "unit dimension currency_eur storage int64 base EUR_cent\n"
    ++ "unit EUR_cent: currency_eur\n\n"
    ++ "schema FxRate scope ttl 1_h:\n    base_code: String\n    quote_code: String\n"
    ++ "    rate_num: Int\n    rate_den: Int\n    rate_f: Float\n\n".

:- func fx_pair(string, string) = string.

fx_pair(Selector, Fields) =
    currency_units ++ "unit fx_pair USD_to_EUR: currency_usd to currency_eur\n"
    ++ "    via FxRate where " ++ Selector ++ "\n    field " ++ Fields ++ "\n".

    % Currency methods -- [LUNI.13.4] - [LUNI.13.6].
    %
:- func currency_rule(string) = string.

currency_rule(Body) =
    currency_units
    ++ "unit USD: currency_usd = x * 100\n"
    ++ "unit fx_pair USD_to_EUR: currency_usd to currency_eur\n"
    ++ "    via FxRate where base_code == \"USD\" and quote_code == \"EUR\"\n"
    ++ "    field rate_num / rate_den\n\n"
    ++ "schema Order scope logical:\n    entity_id: String key\n"
    ++ "    amount: currency_usd mutable\n    budget_eur: currency_eur mutable\n"
    ++ "\nschema Priced scope logical:\n    entity_id: String key\n"
    ++ "    gross_usd: currency_usd mutable\n\nrule r:\n" ++ Body.

    % Opaque types -- [LOPQ.2.3], [LOPQ.10.1].
    %
:- func opaque_source(string) = string.

opaque_source(Predicate) =
    "opaque type Key over Bytes\nopaque type Signature over Bytes\n\n"
    ++ "schema A scope logical:\n    k: Key key\n    k2: Key mutable\n"
    ++ "    s: Signature mutable\n    raw: Bytes mutable\n\nrule r:\n"
    ++ "    A a where " ++ Predicate ++ "\n->\n    log info \"x\"\n".

    % A `String` or `Bytes` receiver -- [LGRA.9.6.2], [LSTR.4.6].
    %
:- func string_method_source(string) = string.

string_method_source(Let) =
    "schema M scope logical:\n    k: Int key\n    text: String mutable\n"
    ++ "    raw: Bytes mutable\n\nrule r:\n    M m\n->\n    let x = " ++ Let
    ++ "\n    log info \"{x}\"\n".

:- pred test_string_methods(tally::in, tally::out, io::di, io::uo) is det.

test_string_methods(!T, !IO) :-
    % LSTR.4.6: each byte/string conversion spelling is refused with
    % DS_VALIDATE_BYTES_CONVERSION_RETIRED; these are the spellings no vector
    % drives.
    check_validate_error("LSTR.4.6 encode is refused, any encoding",
        string_method_source("m.text.encode(\"UTF-8\")"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("LSTR.4.6 decode is refused",
        string_method_source("m.raw.decode(\"latin1\")"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("LSTR.4.6 an unregistered encoding is the "
            ++ "retirement, not DS_VALIDATE_UNKNOWN_ENCODING",
        string_method_source("m.text.encode(\"shift-jis\")"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("LSTR.4.6 bytes_to_utf8 is refused",
        string_method_source("bytes_to_utf8(m.raw)"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("LSTR.4.6 bytes_to_int_le is refused",
        string_method_source("bytes_to_int_le(m.raw, 4)"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("LSTR.4.6 a String :: Bytes cast is refused",
        string_method_source("m.text :: Bytes"),
        dv_bytes_conversion_retired, !T, !IO),
    check_validate_error("[LGRA.9.6.2] a member a String does not have",
        string_method_source("m.text.frobnicate()"),
        dv_unknown_member, !T, !IO),
    check_validate_error("[LGRA.9.6.2] Bytes has no members",
        string_method_source("m.raw.to_int(4)"),
        dv_unknown_member, !T, !IO).

    % Members -- [LGRA.9.6.2], [LGRA.9.6.3].
    %
:- pred test_members(tally::in, tally::out, io::di, io::uo) is det.

test_members(!T, !IO) :-
    check_validated("[LEXP.3.7.1] `.bit_count` on an Int slot",
        literal_rule("    S s where s.n.bit_count > 1\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validate_error("[LGRA.9.6.2] a zero-argument member with parens",
        literal_rule("    S s where s.n.bit_count() > 1\n->\n"
            ++ "    log info \"x\"\n"),
        dv_unknown_member, !T, !IO),
    check_validate_error("[LGRA.9.6.2] a member with arguments, written bare",
        literal_rule("    S s where s.seen.floor > s.seen\n->\n"
            ++ "    log info \"x\"\n"),
        dv_unknown_member, !T, !IO),
    check_validated("[LTIM.3.2.1] a component through `.local(tz)`",
        literal_rule("    S s where s.seen.local(\"Europe/Paris\").hour < 22\n"
            ++ "->\n    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LTIM.7.1] `.floor(d)` answers a Time",
        literal_rule("    S s where s.seen.floor(1_h) <= s.seen\n->\n"
            ++ "    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LTIM.4.3.1] `.add_months(n)` on a Date answers a Date",
        literal_rule("    S s where s.day.add_months(1) > s.day\n->\n"
            ++ "    log info \"x\"\n"),
        !T, !IO),
    check_validate_error("[LGRA.9.6.3] `utc(t)` names its member",
        literal_rule("    S s where utc(s.seen).hour > 8\n->\n"
            ++ "    log info \"x\"\n"),
        dv_retired_builtin_spelling, !T, !IO),
    check_validate_error("[LGRA.9.6.3] `bit_count(x)` names its member",
        literal_rule("    S s where bit_count(s.n) > 1\n->\n"
            ++ "    log info \"x\"\n"),
        dv_retired_builtin_spelling, !T, !IO),
    check_validate_error("[LGRA.9.6.3] `is_null(x)` names `x is null`",
        literal_rule("    S s where is_null(s.n)\n->\n"
            ++ "    log info \"x\"\n"),
        dv_retired_builtin_spelling, !T, !IO),
    check_validate_error("[LIMP.3.3.4] a bare `floor(x)` with no import of math",
        literal_rule("    S s where floor(s.n) > 1\n->\n    log info \"x\"\n"),
        dv_unknown_function, !T, !IO),
    check_validate_error("[LGRA.9.6.3] a formatless `to_string()`",
        literal_rule("    S s\n->\n    let x = s.seen.to_string()\n"
            ++ "    log info \"{x}\"\n"),
        dv_retired_builtin_spelling, !T, !IO),
    check_validated("[LTIM.8.1.2] `to_string(fmt)` keeps its format",
        literal_rule("    S s\n->\n    let x = s.seen.to_string(\"epoch_millis\")\n"
            ++ "    log info \"{x}\"\n"),
        !T, !IO),
    check_validate_error("[LEXP.3.7.2] `.bit_count` on a Float",
        "schema F scope logical:\n    k: Int key\n    v: Float mutable\n\n"
            ++ "rule r:\n    F f where f.v.bit_count > 0\n->\n"
            ++ "    log info \"x\"\n",
        dv_unknown_member, !T, !IO),
    check_validated("[LLET.10.5] a member of a `let` is not a slot",
        literal_rule("    S s\n->\n    let t = s.n + 1\n"
            ++ "    cache key: \"k\" value: t.bit_count\n"),
        !T, !IO).

    % Exact folding -- [LDET.3.3a.7]: rational arithmetic, rounded once to
    % binary64 with ties to even.
    %
    % The expected values are Mercury float literals and `1.0 / 3.0`, both
    % correctly rounded.
    %
:- pred test_exact(tally::in, tally::out, io::di, io::uo) is det.

test_exact(!T, !IO) :-
    check("[LDET.3.3a.7] 0.1 is the binary64 nearest 0.1",
        exact_float("0.1", 0.1), !T, !IO),
    check("[LDET.3.3a.7] a decimal exponent reads exactly",
        exact_float("1.5e-3", 0.0015), !T, !IO),
    check("[LDET.3.3a.7] 1/3 rounds once",
        ( if
            dsc.exact.divide(dsc.exact.from_int64(1i64),
                dsc.exact.from_int64(3i64), Third),
            dsc.exact.to_float(Third, F3),
            F3 = 1.0 / 3.0
          then yes else no ), !T, !IO),
    check("[LDET.3.3a.7] a tie rounds to even, down: 2^53 + 1",
        exact_float("9007199254740993", 9007199254740992.0), !T, !IO),
    check("[LDET.3.3a.7] a tie rounds to even, up: 2^53 + 3",
        exact_float("9007199254740995", 9007199254740996.0), !T, !IO),
    check("[LDET.3.3a.7] the largest finite double",
        exact_float("1.7976931348623157e308", float.max), !T, !IO),
    check("[LDET.3.3a.7] the smallest subnormal",
        exact_float("5e-324", 4.9406564584124654e-324), !T, !IO),
    check("[LDET.3.3a.7] under half the smallest subnormal is zero",
        exact_float("2e-324", 0.0), !T, !IO),
    check("[LDET.3.3a.7] an overflow fails rather than answering an infinity",
        ( if
            dsc.exact.from_decimal("1e309", Big),
            dsc.exact.to_float(Big, _)
          then no else yes ), !T, !IO),
    check("[LDET.3.3a.7] a binary64 converts exactly and back",
        ( if
            dsc.exact.from_float(0.1, Point1),
            dsc.exact.to_float(Point1, Back),
            Back = 0.1
          then yes else no ), !T, !IO),
    check("[LUNI.2.6] `pi` is the binary64 nearest π",
        ( if dsc.exact.to_float(dsc.exact.pi, Pi), Pi = 3.141592653589793
          then yes else no ), !T, !IO),
    check("[LEXP.7.3a] 10 ** -2 is exactly 1/100",
        ( if
            dsc.exact.int_pow(dsc.exact.from_int64(10i64),
                dsc.exact.from_int64(-2i64), Hundredth),
            dsc.exact.to_float(Hundredth, H),
            H = 0.01
          then yes else no ), !T, !IO),
    check("[LDET.3.4.4] a non-integral exponent does not fold",
        ( if
            dsc.exact.from_decimal("0.5", Half),
            dsc.exact.int_pow(dsc.exact.from_int64(2i64), Half, _)
          then no else yes ), !T, !IO),
    check("[LUNI.3.1.5] `0.3_s` is 300000000 ns, not 299999999",
        ( if luni_3_1_5_magnitude_ns("0.3", 1000000000i64, 300000000i64)
          then yes else no ), !T, !IO),
    check("[LUNI.3.1.5] `1.5_h` scales before it truncates",
        ( if luni_3_1_5_magnitude_ns("1.5", 3600000000000i64,
                5400000000000i64)
          then yes else no ), !T, !IO),
    check("[LUNI.3.1.5] an underscored integral magnitude",
        ( if luni_3_1_5_magnitude_ns("1_000", 1000000i64, 1000000000i64)
          then yes else no ), !T, !IO),
    check("[LUNI.2.4.1] `10000000000_s` has no int64 nanoseconds, never "
            ++ "wrapped",
        ( if luni_3_1_5_magnitude_ns("10000000000", 1000000000i64, _)
          then no else yes ), !T, !IO),
    check("[LUNI.2.4.1] the last whole second in int64 nanoseconds",
        ( if luni_3_1_5_magnitude_ns("9223372036", 1000000000i64,
                9223372036000000000i64)
          then yes else no ), !T, !IO),
    check("[LUNI.2.4.1] a checked Int holds -2^63 and refuses 2^63",
        ( if
            TwoTo63 = integer.pow(integer.two, integer.integer(63)),
            dsc.exact.luni_2_4_1_int64(-TwoTo63, I64Min),
            I64Min = int64.min_int64,
            not dsc.exact.luni_2_4_1_int64(TwoTo63, _)
          then yes else no ), !T, !IO),
    check("[LUNI.3.1.5] truncation is toward zero, below it too",
        ( if
            dsc.exact.from_decimal("2.9", Pos),
            dsc.exact.truncate_wrapping_int64(Pos) = 2i64,
            dsc.exact.truncate_wrapping_int64(dsc.exact.negate(Pos)) = -2i64
          then yes else no ), !T, !IO).

:- func exact_float(string, float) = bool.

exact_float(Text, Want) =
    ( if
        dsc.exact.from_decimal(Text, R),
        dsc.exact.to_float(R, Got),
        Got = Want
      then yes else no ).

    % Literal refusals -- [LEXP.10.2.2], [LTAC.7.1], [LLET.10.5], [LTIM.6],
    % [LCST.4.6.1], [LDTL.3.2] / [LDTL.4.1].
    %
:- func literal_rule(string) = string.

literal_rule(Body) =
    "schema S scope logical:\n    entity_id: String key\n    n: Int mutable\n"
    ++ "    seen: Time mutable\n    day: Date mutable\n\n"
    ++ "schema R scope ttl 30_s:\n    k: Int\n\nrule r:\n" ++ Body.

:- pred test_literal_refusals(tally::in, tally::out, io::di, io::uo) is det.

test_literal_refusals(!T, !IO) :-
    check_validated("[LEXP.10.2.2] a non-zero literal divisor",
        literal_rule("    S s where s.n / 2 > 5\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validate_error("[LEXP.10.2.2] modulo by a literal zero",
        literal_rule("    S s where s.n % 0 > 5\n->\n    log info \"x\"\n"),
        dv_div_by_zero, !T, !IO),
    % A `Float` operand makes the operation IEEE's, so `0.0` is not refused
    % ([LEXP.10.2.2], [LEXP.7.15.1]).
    check_validated("[LEXP.10.2.2] floor division by `0.0` compiles",
        literal_rule("    S s where s.n // 0.0 > 5\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LTAC.7.1] a positive `after` delay",
        literal_rule("    S s where s.n > 0\n->\n    log info \"x\"\n"
            ++ "    after 5_s:\n        log info \"y\"\n"),
        !T, !IO),
    check_validate_error("[LTAC.7.1] `after 0_s`",
        literal_rule("    S s where s.n > 0\n->\n    log info \"x\"\n"
            ++ "    after 0_s:\n        log info \"y\"\n"),
        dv_after_nonpositive_duration, !T, !IO),
    check_validated("[LLET.10.5] a method call on a `let` is not a slot",
        literal_rule("    S s\n->\n    let t = s.seen\n"
            ++ "    let x = t.to_string(\"iso8601\")\n    log info \"{x}\"\n"),
        !T, !IO),
    check_validate_error("[LLET.10.5] a slot on a `let`",
        literal_rule("    S s\n->\n    let t = s.n + 1\n"
            ++ "    cache key: \"k\" value: t.slot\n"),
        dv_let_no_slot, !T, !IO),
    check_validated("[LTIM.6.1] a component of `t.utc`",
        literal_rule("    S s where s.seen.utc.hour > 8\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LTIM.6.1] a component of a `Date`, directly",
        literal_rule("    S s where s.day.month == 3\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validate_error("[LTIM.6.1] a name outside the component set",
        literal_rule("    S s where s.seen.utc.nanosecond > 0\n->\n"
            ++ "    log info \"x\"\n"),
        dv_unknown_member, !T, !IO),
    check_validate_error("[LTIM.6.2] a component of a raw `Time`",
        literal_rule("    S s where s.seen.hour > 8\n->\n    log info \"x\"\n"),
        dv_time_needs_tz_context, !T, !IO),
    check_validated("[LCST.4.6.1] the `::` form",
        literal_rule("    S s where s.n::Float > 5.0\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validate_error("[LCST.4.6.1] the `Float(x)` form",
        literal_rule("    S s where Float(s.n) > 5.0\n->\n    log info \"x\"\n"),
        dv_coercion_form_removed, !T, !IO),
    check_validated("[LDTL.3.2] `retain:` equal to the schema TTL",
        literal_rule("    S s\n->\n    emit R k: s.n retain: 30_s\n"),
        !T, !IO),
    check_validated("[LDTL.4.1] `retain:` under `dynamic_ttl`",
        "use default:\n    dynamic_ttl: true\n\n"
            ++ literal_rule("    S s\n->\n    emit R k: s.n retain: 60_s\n"),
        !T, !IO),
    % One code for a construct the settings forbid.
    check_validate_error("[LDTL.3.2] `retain:` without `dynamic_ttl`",
        literal_rule("    S s\n->\n    emit R k: s.n retain: 60_s\n"),
        dv_capability_disabled, !T, !IO),
    check_validate_error("[LDTL.4.1] `retain:` on a `logical` target",
        literal_rule("    S s where s.n > 0\n->\n"
            ++ "    emit S logical entity_id: \"a\" n: 1 retain: 60_s\n"),
        dv_retain_non_ttl, !T, !IO),
    % [LDTL.4.1]: under the extension the expression is typed: an `Int` is
    % not a `Duration`, and a computed `Duration` is admitted.
    check_validate_error("[LDTL.4.1] `retain:` of an `Int` is a type mismatch",
        "use default:\n    dynamic_ttl: true\n\n"
            ++ literal_rule("    S s\n->\n    emit R k: s.n retain: 30\n"),
        dv_type_mismatch, !T, !IO),
    check_validated("[LDTL.4.1] `retain:` of a computed `Duration` is admitted",
        "use default:\n    dynamic_ttl: true\n\n"
            ++ literal_rule("    S s\n->\n    emit R k: s.n retain: s.n * 1_s\n"),
        !T, !IO).

    % Series, service kwargs and continuations -- [LSER.13.13],
    % [LNLS.3.11], [LCSP.4.5], [LCCO.11.2], and the two
    % kwarg-modifier codes no clause registers.
    %
:- func mean_series(string, string) = string.

mean_series(Use, Rule) =
    Use ++ "schema Sensor scope logical:\n    entity_id: String key\n"
    ++ "    val: Float mutable\n\nseries Sensor.val:\n"
    ++ "    mean sliding 10_min\n\nrule check:\n" ++ Rule.

:- func contains_series(string) = string.

contains_series(Use) =
    Use ++ "\n\nschema Sensor scope logical:\n    entity_id: String key\n"
    ++ "    state: Int mutable\n\nseries Sensor.state (by: entity_id):\n"
    ++ "    contains sliding 10_s\n\nrule trig:\n"
    ++ "    Sensor t where contains(t.state, 5)\n->\n    log info \"x\"\n".

:- func label_series(string) = string.

label_series(Use) =
    Use ++ "\n\nschema Sensor scope logical:\n    entity_id: String key\n"
    ++ "    label: String mutable\n\nseries Sensor.label:\n"
    ++ "    count_distinct sliding 10_s\n".

:- func forecast_rule(string) = string.

forecast_rule(Predicate) =
    "schema TimeOfDay scope ttl 1_min:\n    state: String\n\n"
    ++ "schema WeatherResponse scope ttl 1_h:\n    corr: String\n    x: Float\n\n"
    ++ "service weather.get_forecasts:\n"
    ++ "    kwarg entity_id: String literal required\n"
    ++ "    response WeatherResponse\n\n"
    ++ "rule daily_forecast:\n    TimeOfDay t where t.state == \"18:00\"\n->\n"
    ++ "    call weather.get_forecasts entity_id: \"weather.home\" "
    ++ "cooldown: 23_h\n        on " ++ Predicate
    ++ ":\n            log info \"x\"\n".

:- pred test_series_and_call_refusals(tally::in, tally::out,
                                      io::di, io::uo) is det.

test_series_and_call_refusals(!T, !IO) :-
    check_validated("[LSER.13.13] a series read under `default`",
        mean_series("use default\n\n",
            "    Sensor s where s.mean > 5.0\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LSER.13.13] a declaration alone needs no backend",
        mean_series("", "    Sensor s where s.val > 5.0\n->\n"
            ++ "    log info \"x\"\n"),
        !T, !IO),
    % No dialect gates a series backing: every conforming runtime carries
    % [NSBK.2.3]'s magics, so a file with no `use` line compiles a read.
    check_validated("a guard read compiles with no `use` line",
        mean_series("", "    Sensor s where s.mean > 5.0\n->\n"
            ++ "    log info \"x\"\n"),
        !T, !IO),
    check_validated("an interpolated read compiles with no `use` line",
        mean_series("", "    Sensor s where s.val > 5.0\n->\n"
            ++ "    log info \"mean={s.mean}\"\n"),
        !T, !IO),
    check_validated("[LNLS.3.11] a series `contains` with `linear_scan` on",
        contains_series("use default"), !T, !IO),
    check_validate_error("[LNLS.3.11] a series `contains` with it off",
        contains_series("use default:\n    linear_scan: false"),
        dv_nolinscan_series_unbounded, !T, !IO),
    check_validated("[LCSP.4.5] a String series without bounded memory",
        label_series("use default"), !T, !IO),
    % [LCAP.2.1.5]: `constspace` is refused at the `use` block before the
    % String-series check runs; LCSP.4.5's check stays in the tree.
    check_program_refused("[LCAP.2.1.5] a String series under constspace",
        label_series("use default:\n    constspace: true"),
        dv_realtime_deferred, !T, !IO),
    check_validated("[LCCO.11.2] a satisfiable interval",
        forecast_rule("response.x > 60 and response.x < 100"), !T, !IO),
    check_validate_error("[LCCO.11.2] an empty interval",
        forecast_rule("response.x < 60 and response.x > 100"),
        dv_predicate_unsatisfiable, !T, !IO),
    check_validate_error("[LCCO.11.2] a strict bound at the only value",
        forecast_rule("response.x >= 60 and response.x < 60"),
        dv_predicate_unsatisfiable, !T, !IO),
    check_validated("[LGRA.23.2] kwarg modifiers in alphabetical order",
        "service svc.foo:\n    kwarg x: Int literal required\n"
            ++ "    no response\n", !T, !IO),
    check_validated("[LGRA.23.2] kwarg modifiers in any order",
        "service svc.foo:\n    kwarg x: Int required default 5\n"
            ++ "    no response\n", !T, !IO),
    check_front_error("[LGRA.23.2] a kwarg modifier given twice",
        "service svc.foo:\n    kwarg x: Int required required\n"
            ++ "    no response\n",
        parse_kwarg_modifier_duplicate, !T, !IO),
    check_validated("[LGRA.23.2] an Int default on an Int kwarg",
        "service svc.foo:\n    kwarg x: Int default 5\n    no response\n",
        !T, !IO),
    check_validated("[LGRA.23.2] a String default on a String kwarg",
        "service svc.foo:\n    kwarg x: String default \"on\"\n"
            ++ "    no response\n", !T, !IO),
    check_validate_error("[LGRA.23.2] a String default on an Int kwarg",
        "service svc.foo:\n    kwarg x: Int default \"5\"\n"
            ++ "    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    % [LGRA.23.2]: an `Int` literal on a `Float` kwarg is admitted.
    check_validated("[LGRA.23.2] an Int default on a Float kwarg",
        "service svc.foo:\n    kwarg x: Float default 5\n    no response\n",
        !T, !IO),
    check_validate_error("[LGRA.23.2] a Float default on an Int kwarg",
        "service svc.foo:\n    kwarg x: Int default 5.0\n    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    % [LGRA.23.2]: "a kwarg of any other builtin type -- `Bytes`, `Date`,
    % `Duration`, `Interval`, `Json` or `Time` -- takes no `default`".
    check_validate_error("[LGRA.23.2] a Bytes kwarg takes no default",
        "service svc.foo:\n    kwarg x: Bytes default \"ab\"\n"
            ++ "    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validate_error("[LGRA.23.2] a Date kwarg takes no default",
        "service svc.foo:\n    kwarg x: Date default 0\n    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validate_error("[LGRA.23.2] a Duration kwarg takes no default",
        "service svc.foo:\n    kwarg x: Duration default 5\n    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validate_error("[LGRA.23.2] an Interval kwarg takes no default",
        "service svc.foo:\n    kwarg x: Interval default 0\n"
            ++ "    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validate_error("[LGRA.23.2] a Json kwarg takes no default",
        "service svc.foo:\n    kwarg x: Json default \"{}\"\n"
            ++ "    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validate_error("[LGRA.23.2] a Time kwarg takes no default",
        "service svc.foo:\n    kwarg x: Time default 0\n    no response\n",
        dv_service_kwarg_default_type, !T, !IO),
    check_validated("[LGRA.23.2] a kwarg declared with the kind `Schema`",
        "service svc.foo:\n    kwarg x: Schema\n    no response\n", !T, !IO),
    check_validate_error("[LGRA.23.2] a service with no response line",
        "service svc.foo:\n    kwarg x: Int\n",
        dv_service_no_response_decl, !T, !IO),
    check_validated("[LCRS.4.3.2] a `ttl` response schema declaring `corr`",
        response_service("scope ttl 1_min","    corr: String\n"), !T, !IO),
    check_validate_error("[LGRA.23.2] `response Int` is not a schema",
        "service svc.foo:\n    response Int\n",
        dv_service_response_not_schema, !T, !IO),
    check_validate_error("[LGRA.23.2] `response Schema` is not a schema",
        "service svc.foo:\n    response Schema\n",
        dv_service_response_not_schema, !T, !IO),
    check_validate_error("[LGRA.22.7] `response` naming no type",
        "service svc.foo:\n    response Nope\n",
        dv_unknown_type, !T, !IO),
    check_validate_error("[LCRS.4.3.2] a response schema that is not `ttl`",
        response_service("scope logical", "    corr: String key\n"),
        dv_service_response_not_ttl, !T, !IO),
    check_validate_error("[LCRS.4.3.2] a response schema without `corr`",
        response_service("scope ttl 1_min","    other: String\n"),
        dv_service_response_no_corr, !T, !IO),
    check_validate_error("[LCRS.4.3.2] a nullable `corr` is not `corr`",
        response_service("scope ttl 1_min","    corr: String?\n"),
        dv_service_response_no_corr, !T, !IO),
    check_validate_error("[LCRS.4.3.2] an `Int` `corr` is not `corr`",
        response_service("scope ttl 1_min","    corr: Int\n"),
        dv_service_response_no_corr, !T, !IO),
    check_validated("[LGRA.23.2] a String default on a String kwarg",
        "service svc.foo:\n    kwarg x: String default \"on\"\n"
            ++ "    no response\n", !T, !IO).

    % A service answering with `Reply`, declared with `Lifecycle` and `Slots`.
    %
:- func response_service(string, string) = string.

response_service(Lifecycle, Slots) =
    "schema Reply " ++ Lifecycle ++ ":\n" ++ Slots ++ "    v: Int\n\n"
    ++ "service svc.foo:\n    kwarg x: Int\n    response Reply\n".

    % Series declarations -- [LSER.13.11], [LSER.15.1].
    %
:- func declared_series(string, string) = string.

declared_series(Options, Rest) =
    "use default\n\nschema Sensor scope logical:\n"
    ++ "    entity_id: String key\n    val: Float mutable\n\n"
    ++ "series Sensor.val" ++ Options ++ ":\n" ++ Rest.

:- pred test_series_declarations(tally::in, tally::out, io::di, io::uo)
    is det.

test_series_declarations(!T, !IO) :-
    check_validated("[LSER.15.1] a line with no accuracy phrase",
        declared_series("", "    mean sliding 10_min\n"), !T, !IO),
    check_validate_error("[LSER.15.1] an accuracy phrase",
        declared_series("", "    mean sliding 10_min tolerance 0.1\n"),
        dv_series_no_exact_backing, !T, !IO),
    check_validate_error("[LSER.13.11] a block option given twice",
        declared_series(" (by: entity_id, by: entity_id)",
            "    mean sliding 10_min\n"),
        dv_series_duplicate_kwarg, !T, !IO),
    % A cold read is the read's own answer ([LSER.19.8]); `warmed_up` is no
    % builtin and no reserved word.
    check_validate_error("[LGRA.22.7] `warmed_up(s)` names no function",
        declared_series("", "    mean sliding 10_min\n\nrule r:\n"
            ++ "    Sensor s where warmed_up(s)\n->\n"
            ++ "    log info \"x\"\n"),
        dv_unknown_function, !T, !IO).

    % `within` windows and read functions -- [LTHE.4.7], [LGRA.9.8.2].
    %
:- func alarm_rule(string, string) = string.

alarm_rule(Slots, Pattern) =
    "schema Alarm scope logical:\n    state: Int key\n" ++ Slots
    ++ "\nrule r:\n    " ++ Pattern ++ "\n->\n    log info \"x\"\n".

:- func read_rule(string) = string.

read_rule(Let) =
    "schema Trig scope logical:\n    k: Int key\n\n"
    ++ "schema Reading scope logical:\n    val: Int key\n\n"
    ++ "rule r:\n    Trig t where t.k > 0\n->\n    let v = " ++ Let
    ++ "\n    log info \"{v}\"\n".

:- pred test_window_read(tally::in, tally::out, io::di, io::uo) is det.

test_window_read(!T, !IO) :-
    check_validated("a bare `within` on a schema with `ts`",
        alarm_rule("    ts: Time\n", "Alarm a within 5_min where a.state > 0"),
        !T, !IO),
    % [LTIM.2.7.1]: the window is the fact's age from its entry stamp, so no
    % `ts` is needed.
    check_validated("[LTIM.2.7.1] a bare `within` on a schema with no `ts`",
        alarm_rule("", "Alarm a within 5_min where a.state > 0"),
        !T, !IO),
    check_validate_error("[LTHE.4.7] a bare `within 0_s`",
        alarm_rule("    ts: Time\n", "Alarm a within 0_s where a.state > 0"),
        dv_zero_within, !T, !IO),
    check_validate_error("[LTHE.4.7] `then ... within 0_s`",
        alarm_rule("    ts: Time\n",
            "Alarm a then Alarm b within 0_s where a.state > b.state"),
        dv_zero_within, !T, !IO),
    % [LTIM.2.7.1]: a negated pattern's window, and a window named by
    % a `time` const, are judged as a literal's is.
    check_validate_error("[LTIM.2.7.1] `no X within 0_s`",
        alarm_rule("", "Alarm a where a.state > 0\n    no Alarm within 0_s"),
        dv_zero_within, !T, !IO),
    check_validate_error("[LTIM.2.7.1] `within Z` for `const Z = 0_s`",
        alarm_rule("\nconst Z = 0_s\n",
            "Alarm a within Z where a.state > 0"),
        dv_zero_within, !T, !IO),
    check_validated("[LTIM.2.7.1] `within Z` for `const Z = 5_min`",
        alarm_rule("\nconst Z = 5_min\n",
            "Alarm a within Z where a.state > 0"),
        !T, !IO),
    check_validated("[LGRA.9.8.2] `cached()` as the whole `let` RHS",
        read_rule("cached(\"k\")"), !T, !IO),
    check_validate_error("[LGRA.9.8.2] `cached()` embedded in a `let` RHS",
        read_rule("abs(cached(\"k\"))"), dv_let_impure_embedded, !T, !IO),
    % `cached(key)` is the only read function, so `latest(...)` is an unknown
    % function whatever its argument names.
    check_validate_error("[LGRA.9.8.2] `latest()` naming a schema is unknown",
        read_rule("latest(Reading)"), dv_unknown_function, !T, !IO),
    check_validate_error("[LGRA.9.8.2] `latest()` naming no schema is unknown",
        read_rule("latest(NoSuchThing)"), dv_unknown_function, !T, !IO).

    % Continuation shape, rate modifiers, interpolation bodies, `json()`,
    % `.date()`, a type name as a value -- [LECC.1.4], [LCCO.10.2],
    % [LCDB.5.5], [LGRA.2.9.6.9], [LGRA.9.8.3], [LTIM.3.3.2].
    %
:- func svc_rule(string, string) = string.

svc_rule(Header, Rhs) =
    "schema T scope logical:\n    v: Int key\n    s: String mutable\n"
    ++ "    fired: Time mutable\n    d: Date mutable\n\n"
    ++ "schema R scope ttl 1_min:\n    corr: String\n    code: Int\n\n"
    ++ "service svc.a:\n    kwarg k: Int\n    response R\n"
    ++ "service svc.b:\n    kwarg k: Int\n    response R\n"
    ++ "service svc.c:\n    kwarg k: Int\n    no response\n\n"
    ++ "rule r" ++ Header ++ ":\n    T t where t.v > 0\n->\n" ++ Rhs.

    % The `LTIM.2.x` fixtures' shape: a rule gated on `now()` against an
    % instant written as `Threshold`.
    %
:- func now_gate_rule(string) = string.

now_gate_rule(Threshold) =
    "schema Sensor scope logical:\n    entity_id: String key\n\n"
    ++ "rule after_5_s:\n    Sensor where now() > " ++ Threshold
    ++ "\n->\n    log info \"time passed\"\n".

    % A rule gated on an `Int` expression written as `Value`.
    %
:- func int_gate_rule(string) = string.

int_gate_rule(Value) =
    "schema Sensor scope logical:\n    entity_id: String key\n"
    ++ "    n: Int mutable\n\n"
    ++ "rule counted:\n    Sensor s where s.n > " ++ Value
    ++ "\n->\n    log info \"counted\"\n".

:- pred test_wrong_code_second(tally::in, tally::out, io::di, io::uo) is det.

test_wrong_code_second(!T, !IO) :-
    check_validated("[LECC.1.4] a four-segment error pattern",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        error adapter.failed.scope.sub:\n"
            ++ "            log info \"x\"\n"), !T, !IO),
    check_validate_error("[LECC.1.4] a five-segment error pattern",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        error adapter.failed.scope.sub.deeper:\n"
            ++ "            log info \"x\"\n"),
        dv_error_pattern_too_deep, !T, !IO),
    % [LECC.6.4]: a pattern's family is `request`, `internal` or `adapter`;
    % an adapter's own name is not one.
    check_validate_error("[LECC.6.4] an unknown error family is refused",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        error transport:\n"
            ++ "            log info \"x\"\n"),
        dv_error_pattern_unknown_family, !T, !IO),
    check_validate_error("[LECC.6.4] an adapter's name is not a family",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        error svc.timeout:\n"
            ++ "            log info \"x\"\n"),
        dv_error_pattern_unknown_family, !T, !IO),
    check_validated("[LECC.6.4] the `adapter` family and a leaf under it",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        error adapter:\n"
            ++ "            log info \"a\"\n"
            ++ "        error adapter.throttled:\n"
            ++ "            log info \"b\"\n"), !T, !IO),
    check_validated("[LCCO.10.2] a chain two levels deep",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        on response.code == 200:\n"
            ++ "            call svc.b cooldown: 1_min as \"b\"\n"
            ++ "                on response.code == 200:\n"
            ++ "                    log info \"x\"\n"), !T, !IO),
    check_validate_codes("[LCCO.3.8] a nested continued call with no `as`",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        on response.code == 200:\n"
            ++ "            call svc.b cooldown: 1_min\n"
            ++ "                on response.code == 200:\n"
            ++ "                    log info \"x\"\n"),
        [dv_nested_continued_call_as], !T, !IO),
    check_validate_codes("[LCCO.3.8] a continued call in an `after` body "
            ++ "with no `as`",
        svc_rule("", "    after 5_s:\n"
            ++ "        call svc.b cooldown: 1_min\n"
            ++ "            on response.code == 200:\n"
            ++ "                log info \"x\"\n"),
        [dv_nested_continued_call_as], !T, !IO),
    check_validate_codes("[LCCO.3.8] a continued call in a `timeout` body "
            ++ "with a computed `as`",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        timeout 5_s:\n"
            ++ "            call svc.b cooldown: 1_min as t.s\n"
            ++ "                on response.code == 200:\n"
            ++ "                    log info \"x\"\n"),
        [dv_nested_continued_call_as], !T, !IO),
    check_validate_codes("[LCCO.3.8] a nested continued call with an "
            ++ "interpolated `as`",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        on response.code == 200:\n"
            ++ "            call svc.b cooldown: 1_min as \"b{t.s}\"\n"
            ++ "                on response.code == 200:\n"
            ++ "                    log info \"x\"\n"),
        [dv_nested_continued_call_as], !T, !IO),
    check_validated("[LCCO.3.8] a plain call in an `after` body needs no `as`",
        svc_rule("", "    after 5_s:\n"
            ++ "        call svc.b cooldown: 1_min\n"), !T, !IO),
    check_validated("[LCCO.3.8] a continued call in an `after` body with a "
            ++ "literal `as`",
        svc_rule("", "    after 5_s:\n"
            ++ "        call svc.b cooldown: 1_min as \"b\"\n"
            ++ "            on response.code == 200:\n"
            ++ "                log info \"x\"\n"), !T, !IO),
    check_validate_error("[LCCO.10.2] a chain three levels deep",
        svc_rule("", "    call svc.a cooldown: 1_min\n"
            ++ "        on response.code == 200:\n"
            ++ "            call svc.b cooldown: 1_min\n"
            ++ "                on response.code == 200:\n"
            ++ "                    call svc.c cooldown: 1_min\n"
            ++ "                        on response.code == 200:\n"
            ++ "                            log info \"x\"\n"),
        dv_continuation_chain_too_deep, !T, !IO),
    check_validated("a call cooldown in a rule with no rate modifier",
        svc_rule("", "    call svc.a cooldown: 2_min\n"), !T, !IO),
    check_validate_error("a call cooldown inside a rule cooldown",
        svc_rule(" cooldown 5_min", "    call svc.a cooldown: 2_min\n"),
        dv_call_cool_inside_rule_cool, !T, !IO),
    check_validated("[LCDB.5.6] `cooldown 0_s` is legal",
        svc_rule(" cooldown 0_s", "    log info \"x\"\n"), !T, !IO),
    check_validate_error("[LCDB.5.5] a negative rule cooldown",
        svc_rule(" cooldown -5_min", "    log info \"x\"\n"),
        dv_rate_negative_duration, !T, !IO),
    % [LGRA.9.6.1]: a literal is a primary and takes a suffix, a member or a
    % cast.
    check_validated("[LGRA.9.6.1] a member on a parenthesised literal",
        int_gate_rule("(5).bit_count"), !T, !IO),
    % [LTIM.14]: DS reads no temporal text. `s.to_time(...)` and
    % `s.to_date(...)` are no members of `String`, whatever their arguments,
    % and the instant is a `calendar` call.
    check_validate_error("[LTIM.14] `to_time` is no member of a `String`",
        now_gate_rule("\"5000000000\".to_time(\"epoch_nanos\")"),
        dv_unknown_member, !T, !IO),
    check_validate_error("[LTIM.14] `to_date` is no member of a `String`",
        now_gate_rule("(\"2026-01-01\").to_date()"),
        dv_unknown_member, !T, !IO),
    check_validated("[LTIM.14.1] a `calendar.time` threshold",
        "import calendar\n\n" ++
            now_gate_rule("calendar.time(1970, 1, 1, 0, 0, 5)"), !T, !IO),
    check_validated("[LTIM.14.1] `calendar.time` bare, after a selective "
            ++ "import",
        "from calendar import time\n\n" ++
            now_gate_rule("time(1970, 1, 1)"), !T, !IO),
    check_validate_error("[LIMP.3.3.4] a bare `time(...)` with no import of "
            ++ "calendar is an unknown function",
        now_gate_rule("time(1970, 1, 1)"),
        dv_unknown_function, !T, !IO),
    check_validate_error("[LTIM.14.1] `calendar.time` takes 3, 6 or 7 fields",
        "import calendar\n\n" ++
            now_gate_rule("calendar.time(1970, 1, 1, 0)"),
        dv_bad_arity, !T, !IO),
    check_validate_error("[LTIM.14.1] `calendar.date` takes 3 fields",
        "import calendar\n\n" ++
            now_gate_rule("calendar.time(1970, 1, 1) + "
                ++ "(calendar.date(1970, 1) - calendar.date(1970, 1, 1))"),
        dv_bad_arity, !T, !IO),
    check_validate_error("[LTIM.14.1] a `Float` field is refused",
        "import calendar\n\n" ++
            now_gate_rule("calendar.time(1970.0, 1, 1)"),
        dv_bad_operand_type, !T, !IO),
    check_validate_error("[LCST.4.5.2] `s::Time?` is refused ([LTIM.14])",
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    s: String mutable\n\n"
            ++ "rule after:\n    Sensor x where now() > x.s::Time?\n"
            ++ "->\n    log info \"after\"\n",
        dv_cast_undefined, !T, !IO),
    check_validated("[LTIM.14.3] a `const` over a `calendar` call folds",
        "import calendar\n\nconst LAUNCH = calendar.time(2026, 1, 1)\n\n"
            ++ now_gate_rule("LAUNCH"), !T, !IO),
    check_validate_error("[LTIM.14.3] a `const` whose fold raises DOMAIN",
        "import calendar\n\nconst BAD = calendar.date(2026, 2, 30)\n\n"
            ++ now_gate_rule("calendar.time(1970, 1, 1)"),
        dv_const_not_foldable, !T, !IO),
    check_validate_error("[LTIM.14.3] a `const` whose fold is "
            ++ "NOT_REPRESENTABLE",
        "import calendar\n\nconst BAD = calendar.time(1677, 9, 21)\n\n"
            ++ now_gate_rule("calendar.time(1970, 1, 1)"),
        dv_const_not_foldable, !T, !IO),
    check_validated("[LGRA.9.6.1] a cast on a bare literal",
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    v: Float mutable\n\n"
            ++ "rule high:\n    Sensor s where s.v > 5::Float\n"
            ++ "->\n    log info \"high\"\n", !T, !IO),
    check_validate_error("[LGRA.2.9.6.9] an empty `{}`",
        svc_rule("", "    log info \"empty {}\"\n"),
        dv_interp_bad_path, !T, !IO),
    % An interpolation body is a name or path, so a call is refused; bound to
    % a `let`, it is interpolated by name.
    check_validate_error("[LGRA.2.9.6.9] a call as an interpolation body",
        svc_rule("", "    log info \"x={abs(5)}\"\n"),
        dv_interp_bad_path, !T, !IO),
    check_validated("[LGRA.2.9.6.2] the call bound to a `let` and interpolated",
        svc_rule("", "    let n = abs(5)\n    log info \"x={n}\"\n"), !T, !IO),
    % [LGRA.9.8.3]: every `json()` is refused at the call, whatever its
    % argument.
    check_validate_error("[LGRA.9.8.3] `json()` on valid JSON text",
        svc_rule("", "    let j = json(\"[1, 2]\")\n"
            ++ "    log info \"{j}\"\n"),
        dv_json_literal_refused, !T, !IO),
    check_validate_error("[LGRA.9.8.3] `json()` on text that is not JSON",
        svc_rule("", "    let j = json(\"{bad json}\")\n"
            ++ "    log info \"{j}\"\n"),
        dv_json_literal_refused, !T, !IO),
    check_validate_error("[LGRA.9.8.3] `json()` on a slot",
        svc_rule("", "    let j = json(t.s)\n    log info \"{j}\"\n"),
        dv_json_literal_refused, !T, !IO),
    check_validate_error("[LGRA.9.8.3] `json()` as a `const` value",
        "const EMPTY = json(\"{}\")\n\n" ++ svc_rule("", "    log info \"x\"\n"),
        dv_json_literal_refused, !T, !IO),
    check_validate_error("[LTIM.3.3.2] `.date()` with no timezone",
        "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "    d: Date mutable\n\nrule r:\n"
            ++ "    E e where e.fired.date() == e.d\n->\n    log info \"x\"\n",
        dv_date_needs_tz, !T, !IO),
    check_validate_error("a schema name in an expression",
        svc_rule("", "    log info \"x\"\n") ++ "\nrule q:\n"
            ++ "    T t where t.v == T\n->\n    log info \"y\"\n",
        dv_unknown_const, !T, !IO),
    check_resolve_error("[LOPQ.2.3] an opaque type and a schema share a name",
        "opaque type Machine over Bytes\nschema Machine scope logical:\n"
            ++ "    id: String key\n",
        dv_name_collision, !T, !IO).

    % The warning channel -- [LCST.4.5.1], [LSIG.3.6].
    %
:- func cast_rule(string) = string.

cast_rule(Predicate) =
    "schema S scope logical:\n    k: Int key\n    x: Float mutable\n\n"
    ++ "rule r:\n    S s where " ++ Predicate ++ "\n->\n    log info \"x\"\n".

:- func integral_series(string, string) = string.

integral_series(Line, Rules) =
    "use realtime\n\nschema F scope logical:\n"
    ++ "    entity_id: String key\n    q: Float mutable\n    ts: Time\n\n"
    ++ "series F.q:\n    " ++ Line ++ "\n" ++ Rules.

:- pred test_warnings(tally::in, tally::out, io::di, io::uo) is det.

test_warnings(!T, !IO) :-
    check_validate_warning("[LCDB.7.9] a cooldown over an empty key warns",
        "schema A scope logical:\n    c: Float mutable\n\n"
            ++ "rule r cooldown 5_min:\n    A a where a.c > 1.0\n->\n"
            ++ "    log info \"x\"\n",
        dv_rule_wide_rate_window, !T, !IO),
    check_validated_quietly("[LCDB.7.9] a keyed schema's cooldown is quiet",
        "schema A scope logical:\n    k: String key\n    c: Float mutable\n\n"
            ++ "rule r cooldown 5_min:\n    A a where a.c > 1.0\n->\n"
            ++ "    log info \"{a.k}\"\n",
        !T, !IO),
    check_validated_quietly("[LCDB.7.9] no rate modifier, no warning",
        "schema A scope logical:\n    c: Float mutable\n\n"
            ++ "rule r:\n    A a where a.c > 1.0\n->\n    log info \"x\"\n",
        !T, !IO),
    check_validated_quietly("[LCST.4.5.1] a real conversion warns nothing",
        cast_rule("s.k::Float > 1.0"), !T, !IO),
    check_validate_warning("[LCST.4.5.1] an identity cast is a warning",
        cast_rule("s.x::Float > 1.0"), dv_cast_identity, !T, !IO),
    % [LSIG.3.6] is reached only under `realtime`, which [LCAP.2.1.5] refuses
    % at the `use` line, so these call the series checks directly.
    check_series_warning("[LSIG.3.6] a gap-hold integral with no clock",
        integral_series("integral sliding 5_min", ""),
        yes(dv_series_gap_hold_no_clock), !T, !IO),
    check_series_warning("[LSIG.3.6] `gap zero` needs no clock",
        integral_series("integral sliding 5_min gap zero", ""), no, !T, !IO),
    check_series_warning("[LSIG.3.6] a `within` window is the clock",
        integral_series("integral sliding 5_min",
            "\nrule tick:\n    F f within 10_s where f.q > 0.0\n->\n"
                ++ "    log info \"x\"\n"),
        no, !T, !IO),
    check_program_refused("[LCAP.2.1.5] the same program is refused first",
        integral_series("integral sliding 5_min", ""),
        dv_realtime_deferred, !T, !IO).

    % `dsc.series`'s checks alone, on the resolved file: the one diagnostic
    % wanted, or none at all.
    %
    % The settings are the built-in `realtime` dialect's, given directly,
    % since [LCAP.2.1.5] refuses `use realtime`.
    %
:- pred check_series_warning(string::in, string::in, maybe(ds_validate)::in,
                             tally::in, tally::out, io::di, io::uo) is det.

check_series_warning(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF0)),
        map.search(builtin_registry, "realtime", Realtime),
        RF = RF0 ^ rf_program := program_settings("realtime",
            Realtime ^ dl_settings, map.init),
        lser_7_1_declarations(RF, Ds),
        (
            Want = yes(Code),
            list.member(D, Ds),
            D ^ dg_code = dc_validate(Code),
            D ^ dg_severity = sev_warning
        ;
            Want = no,
            Ds = []
        )
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % A response read by a sibling rule -- [LCRS.5.5], and `CallResponse`
    % refused -- [LCRS.4.3.3]. `Head` is the sibling's pattern head.
    %
:- func sibling_source(string, string) = string.

sibling_source(Head, Predicate) =
    "schema LightResponse scope ttl 1_h:\n    corr: String\n"
    ++ "    success: Bool\n    error_code: String\n\n"
    ++ "schema Trig scope logical:\n    v: Int key\n\n"
    ++ "service light.turn_on:\n    kwarg entity_id: String literal required\n"
    ++ "    response LightResponse\n\n"
    ++ "rule trigger:\n    Trig t where t.v > 0\n->\n"
    ++ "    call light.turn_on entity_id: \"x\" cooldown: 30_s as \"corr1\"\n\n"
    ++ "rule check:\n    " ++ Head ++ " r where r.corr == \"corr1\" and "
    ++ Predicate ++ "\n->\n    log info \"y\"\n".

:- pred test_sibling_responses(tally::in, tally::out, io::di, io::uo) is det.

test_sibling_responses(!T, !IO) :-
    check_validated("[LCRS.5.5] a response read as any fact is",
        sibling_source("LightResponse", "r.success == true"), !T, !IO),
    check_validate_error("[LCRS.5.5] a response slot it does not declare",
        sibling_source("LightResponse", "r.foo == true"),
        dv_unknown_slot, !T, !IO),
    % Refused by `resolve`, which is where an unknown head would be.
    check_resolve_error("[LCRS.4.3.3] a `CallResponse` pattern is refused",
        sibling_source("CallResponse", "r.corr != \"\""),
        dv_call_response_retired, !T, !IO),
    check_validate_error("[LCRS.4.3.3] a `CallResponse` declaration too",
        "schema CallResponse scope ttl 1_h:\n    corr: String\n",
        dv_call_response_retired, !T, !IO).

    % `call` kwarg values -- typed, and matched to the declared kwarg type.
    %
:- func call_value_source(string) = string.

call_value_source(Value) =
    "schema S scope logical:\n    k: Int key\n    name: String mutable\n\n"
    ++ "service svc.a:\n    kwarg n: Int\n    kwarg label: String\n"
    ++ "    no response\n\n"
    ++ "rule r:\n    S s where s.k > 0\n->\n"
    ++ "    call svc.a " ++ Value ++ " cooldown: 1_min\n".

:- pred test_call_kwarg_values(tally::in, tally::out, io::di, io::uo) is det.

test_call_kwarg_values(!T, !IO) :-
    check_validated("a call kwarg of its declared type",
        call_value_source("n: s.k label: s.name"), !T, !IO),
    % [LADP.8.5.4]: a builtin-typed kwarg takes a value of its type.
    check_validate_error("[LADP.8.5.4] a String given to an Int kwarg is "
            ++ "refused",
        call_value_source("n: s.name"), dv_type_mismatch, !T, !IO),
    check_validated("[LADP.8.5.4] and with the cast written, it is admitted",
        call_value_source("label: s.k::String"), !T, !IO),
    check_validate_error("a call kwarg value's own error surfaces",
        call_value_source("n: s.nope"), dv_unknown_slot, !T, !IO).

:- pred test_opaque(tally::in, tally::out, io::di, io::uo) is det.

test_opaque(!T, !IO) :-
    check_validated("[LOPQ.3.1] two values of one opaque type are equatable",
        opaque_source("a.k == a.k2"), !T, !IO),
    check_validate_error("[LOPQ.2.3] two opaque types do not compare",
        opaque_source("a.k == a.s"), dv_opaque_type_mismatch, !T, !IO),
    check_validate_error("[LOPQ.2.3] nor an opaque type and its representation",
        opaque_source("a.k != a.raw"), dv_opaque_type_mismatch, !T, !IO),
    % [LOPQ.2.3]'s other two positions: an assignment and an argument
    % binding.
    check_validate_error("[LOPQ.2.3] an emit slot takes no foreign opaque",
        "opaque type Key over Bytes\nopaque type Signature over Bytes\n\n"
            ++ "schema A scope logical:\n    k: Key key\n"
            ++ "    s: Signature mutable\n\n"
            ++ "schema Out scope logical:\n    ok: Key key\n\n"
            ++ "rule r:\n    A a\n->\n    emit Out logical ok: a.s\n",
        dv_opaque_type_mismatch, !T, !IO),
    check_validate_error("[LOPQ.2.3] nor a call kwarg",
        "opaque type Key over Bytes\n\n"
            ++ "service sink.put:\n    kwarg id: Key\n    no response\n\n"
            ++ "schema A scope logical:\n    k: Key key\n"
            ++ "    raw: Bytes mutable\n\n"
            ++ "rule r:\n    A a\n->\n"
            ++ "    call sink.put id: a.raw nocooldown\n",
        dv_opaque_type_mismatch, !T, !IO),

    check_validate_error("[LOPQ.10.1] only `over Bytes` is admitted",
        "opaque type Weight over Float\n", dv_opaque_unsupported_repr,
        !T, !IO).

:- pred test_currency(tally::in, tally::out, io::di, io::uo) is det.

test_currency(!T, !IO) :-
    check_validated("[LUNI.13.4] convert then round, compared in kind",
        currency_rule("    Order o where o.amount.to_currency(USD_to_EUR)"
            ++ ".round(\"half_even\") > o.budget_eur\n->\n    log info \"x\"\n"),
        !T, !IO),
    check_validated("[LUNI.13.5.2] a rounded product lands in a currency slot",
        currency_rule("    Order o\n->\n    emit Priced logical entity_id: "
            ++ "o.entity_id gross_usd: (o.amount * 1.07).round(\"half_up\")\n"),
        !T, !IO),
    check_validated("[LUNI.13.5.2] currency times Int stays exact",
        currency_rule("    Order o\n->\n    emit Priced logical entity_id: "
            ++ "o.entity_id gross_usd: o.amount * 12\n"), !T, !IO),
    check_validate_error("[LUNI.13.5.2] an unrounded product",
        currency_rule("    Order o\n->\n    emit Priced logical entity_id: "
            ++ "o.entity_id gross_usd: o.amount * 1.07\n"),
        dv_currency_implicit_round, !T, !IO),
    check_validate_error("[LUNI.13.5.1] `.round()` with no mode",
        currency_rule("    Order o where o.amount.round() > o.amount\n->\n"
            ++ "    log info \"x\"\n"),
        dv_currency_round_no_mode, !T, !IO),
    check_validate_error("[LUNI.13.6] a mode outside the six",
        currency_rule("    Order o where o.amount.round(\"banker\") > o.amount"
            ++ "\n->\n    log info \"x\"\n"),
        dv_currency_unknown_round_mode, !T, !IO),
    check_validate_error("[LUNI.13.6] a mode that is not a literal",
        currency_rule("    Order o where o.amount.round(42) > o.amount\n->\n"
            ++ "    log info \"x\"\n"),
        dv_currency_round_arg_not_string, !T, !IO),
    check_validate_error("[LUNI.13.7] converted, then compared across kinds",
        currency_rule("    Order o where o.amount.to_currency(USD_to_EUR)"
            ++ ".round(\"half_even\") > o.amount\n->\n    log info \"x\"\n"),
        dv_currency_cross_compare, !T, !IO),
    check_validate_error("[LUNI.4.6] `.to_currency` of an undeclared pair",
        currency_rule("    Order o where o.amount.to_currency(Nope)"
            ++ ".round(\"half_even\") > o.budget_eur\n->\n    log info \"x\"\n"),
        dv_fx_pair_unknown, !T, !IO).

:- pred test_unit_decls(tally::in, tally::out, io::di, io::uo) is det.

test_unit_decls(!T, !IO) :-
    % No case names a `units.core` axis, anchor or alias: `dsc` loads
    % `units.core` and refuses a redeclaration ([LUNI.4.1.2], [LIMP.5.1.5]),
    % and these compile with nothing loaded. So does every suite in this file.
    check_validated("[LUNI.4.3] affine bodies over a declared dimension",
        "unit dimension warmth storage float64 base therm\n"
        ++ "unit therm: warmth\n"
        ++ "unit celsius: warmth = x + 273.15\n"
        ++ "unit milli_therm: warmth = x / 1000\n", !T, !IO),
    check_validate_error("[LUNI.4.3] a symbol over no known dimension",
        "unit my_unit: undeclared_dim\n", dv_unit_unknown_dimension, !T, !IO),
    check_validate_error("[LUNI.4.3] a quadratic body is not affine",
        "unit dimension foo storage float64 base bar\nunit bar: foo\n"
        ++ "unit baz: foo = x * x\n", dv_unit_body_not_affine, !T, !IO),
    check_validate_error("[LUNI.4.3] a unit with no `=` that is not its "
            ++ "dimension's base",
        "unit dimension span storage float64 base stride\nunit stride: span\n"
        ++ "unit pace: span\n", dv_unit_body_missing, !T, !IO),
    check_validate_error("[LUNI.4.3] a unit with no `=` that is not its "
            ++ "dimension's base, declared ahead of the base",
        "unit dimension span storage float64 base stride\nunit pace: span\n"
        ++ "unit stride: span\n", dv_unit_body_missing, !T, !IO),
    check_validate_error("[LUNI.4.3] a scalar group's second unit with no `=`",
        "unit scalar ratio storage float64\nunit whole: ratio\n"
        ++ "unit half: ratio\n", dv_unit_body_missing, !T, !IO),
    check_validate_error("[LUNI.4.3] a scalar group's first unit is its base "
            ++ "whatever its body",
        "unit scalar ratio storage float64\nunit half: ratio = x / 2\n"
        ++ "unit whole: ratio\n", dv_unit_body_missing, !T, !IO),
    check_validated("[LUNI.4.3] a unit equal to the base writes `= x`",
        "unit dimension span storage float64 base stride\nunit stride: span\n"
        ++ "unit pace: span = x\n", !T, !IO),
    check_validated("[LUNI.4.3] a scalar group's first unit omits `=`",
        "unit scalar ratio storage float64\nunit whole: ratio\n"
        ++ "unit half: ratio = x / 2\n"
        ++ "unit scalar other storage float64\nunit lone: other\n", !T, !IO),
    check_validate_error("[LUNI.4.5] a formula over no known symbol",
        "unit dimension span storage float64 base stride\nunit stride: span\n"
        ++ "unit formula foo:\n    fwd(x: stride): nope = x\n"
        ++ "    bwd(x: nope): stride = x\n", dv_unit_unknown_symbol, !T, !IO),
    check_validate_error("[LUNI.4.5] a formula with one line",
        "unit dimension span storage float64 base stride\nunit stride: span\n"
        ++ "unit formula foo:\n    fwd(x: stride): stride = x\n",
        dv_unit_formula_pair_arity, !T, !IO),
    check_validate_error("[LUNI.4.5] a formula with three lines",
        "unit dimension span storage float64 base stride\nunit stride: span\n"
        ++ "unit formula foo:\n    fwd(x: stride): stride = x\n"
        ++ "    bwd(x: stride): stride = x\n    again(x: stride): stride = x\n",
        dv_unit_formula_pair_arity, !T, !IO),
    check_validated("[LUNI.4.6] a well-formed fx_pair",
        fx_pair("base_code == \"USD\" and quote_code == \"EUR\"",
            "rate_num / rate_den"),
        !T, !IO),
    check_validate_error("[LUNI.4.6] a selector that is not string equality",
        fx_pair("base_code == \"USD\" and rate_num > 0", "rate_num / rate_den"),
        dv_fx_pair_selector, !T, !IO),
    check_validate_error("[LUNI.4.6] a rate slot that is not Int",
        fx_pair("base_code == \"USD\"", "rate_f / rate_den"),
        dv_fx_pair_field_not_int, !T, !IO),
    check_validate_error("[LUNI.4.6] a rate slot the schema lacks",
        fx_pair("base_code == \"USD\"", "rate_num / nope"),
        dv_fx_pair_unknown_field, !T, !IO).

:- pred test_consts(tally::in, tally::out, io::di, io::uo) is det.

test_consts(!T, !IO) :-
    check_validated("[LGRA.4.1] constants read earlier ones, annotated or not",
        const_source("const A = 1\nconst B = A + 1\nconst S: String = \"x\"\n"
            ++ "const F: Float = 2\n"), !T, !IO),
    check_validate_error("[LGRA.4.1] an annotation its literal contradicts",
        const_source("const N: Int = \"x\"\n"),
        dv_const_annotation_mismatch, !T, !IO),
    check_validate_error("[LGRA.4.1] a type no constant can have",
        const_source("const C: Connection = \"x\"\n"),
        dv_const_bad_annotation, !T, !IO),
    check_validate_error("[LGRA.13.3] a runtime read does not fold",
        const_source("const X = now()\n"),
        dv_const_not_foldable, !T, !IO),
    check_validate_error("[LGRA.13.3] a constant reads a later one",
        const_source("const A = B + 1\nconst B = 2\n"),
        dv_unknown_const, !T, !IO).

:- pred test_let_order(tally::in, tally::out, io::di, io::uo) is det.

test_let_order(!T, !IO) :-
    check_validated("[LLET.12.3] a `let` reads the one above it",
        let_order_source("    let b = t.k\n    let a = b + 1\n"), !T, !IO),
    check_validate_error("[LLET.12.3] a `let` reads the one below it",
        let_order_source("    let a = b + 1\n    let b = t.k\n"),
        dv_unknown_binding, !T, !IO),
    check_validate_error("[LLET.12.3] a `let` reads itself",
        let_order_source("    let a = a + 1\n"),
        dv_unknown_binding, !T, !IO),
    check_validate_error("[LLET.10.6] a group is ordered like the lines",
        let_order_source("    let a = b + 1\n        b = t.k\n"),
        dv_unknown_binding, !T, !IO).

:- pred test_regex(tally::in, tally::out, io::di, io::uo) is det.

test_regex(!T, !IO) :-
    check_toks("[LREG.6.1] `/` after `~` opens a regex literal",
        "s ~ /a\\/b/im", [name("s"), match_op, regex_lit("a\\/b", "im")],
        !T, !IO),
    check_toks("[LREG.6.1] `/` anywhere else is still division",
        "a / b", [name("a"), slash, name("b")], !T, !IO),
    check_toks("[LREG.6.2] `!~` opens one too",
        "s !~ /x/", [name("s"), nmatch_op, regex_lit("x", "")], !T, !IO),
    check_validated("[LREG.2.1] a capture-free `~` in `where` is legal",
        regex_source("    Log e where e.msg ~ /^ERR/i and e.msg !~ /x/\n->\n"
            ++ "    log info \"x\"\n"), !T, !IO),
    check_validated("[LREG.4.2] a capture list whose names fit its groups",
        regex_source("    Log e where (dev, num) = e.msg ~ "
            ++ "/(?<dev>\\w+) on (\\d+)/\n->\n"
            ++ "    log info \"{dev} {num}\"\n"), !T, !IO),
    check_validate_error("[LREG.2.3] a `where` pattern that captures",
        regex_source("    Log e where e.msg ~ /(\\w+)/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_where_has_captures, !T, !IO),
    check_validate_error("[LREG.7.1] RE2's syntax error",
        regex_source("    Log e where e.msg ~ /(unclosed/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_syntax_error, !T, !IO),
    check_validate_error("[LREG.8.4] a lookahead is named, not a syntax error",
        regex_source("    Log e where e.msg ~ /error(?=:)/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_unsupported_feature, !T, !IO),
    check_validate_error("[LREG.5.3] a repeated flag",
        regex_source("    Log e where e.msg ~ /x/ii\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_unknown_flag, !T, !IO),
    check_validate_error("[LREG.5.4] an unknown flag",
        regex_source("    Log e where e.msg ~ /x/x\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_unknown_flag, !T, !IO),
    check_validate_error("[LREG.4.5] a non-String operand",
        regex_source("    Log e where e.num ~ /4/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_non_string_operand, !T, !IO),
    check_validate_error("[LSTR.7.1.1] a Bytes operand",
        regex_source("    Log e where e.raw ~ /a/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_regex_on_bytes, !T, !IO),
    % [LREG.4.1]: a match is legal in `where` only, so a `let` refuses one
    % whatever its capture profile, and the capture form in `let` too.
    check_validate_error("[LREG.4.1] a plain `let` over a capture-free match",
        regex_source("    Log e\n->\n    let x = e.msg ~ /abc/\n"
            ++ "    log info \"{x}\"\n"),
        dv_regex_capture_in_let, !T, !IO),
    check_validate_error("[LREG.4.1] the capture form in a `let`",
        regex_source("    Log e\n->\n    let (a) = e.msg ~ /(\\w+)/\n"
            ++ "    log info \"{a}\"\n"),
        dv_regex_capture_in_let, !T, !IO),
    check_validate_error("[LREG.2.5] `!~` in a `let`",
        regex_source("    Log e\n->\n    let x = e.msg !~ /abc/\n"
            ++ "    log info \"{x}\"\n"),
        dv_regex_let_negated, !T, !IO),
    check_validated("[LREG.4.1] the capture form in `where`",
        regex_source("    Log e where (a, b) = e.msg ~ /(\\w+) (\\w+)/\n->\n"
            ++ "    log info \"{a}{b}\"\n"),
        !T, !IO),
    check_validated("[LREG.4.1] a predicate after the capture reads it",
        regex_source("    Log e where (a) = e.msg ~ /(\\w+)/ and a == \"x\"\n"
            ++ "->\n    log info \"{a}\"\n"),
        !T, !IO),
    check_validate_error("[LREG.4.2] two names for three groups",
        regex_source("    Log e where (a, b) = e.msg ~ /(\\w+) (\\w+) (\\w+)/\n"
            ++ "->\n    log info \"{a}{b}\"\n"),
        dv_regex_binding_length_mismatch, !T, !IO),
    check_validate_error("[LREG.3.3] a named capture under another name",
        regex_source("    Log e where (num) = e.msg ~ /(?<dev>\\w+)/\n->\n"
            ++ "    log info \"{num}\"\n"),
        dv_regex_name_mismatch, !T, !IO),
    check_validate_error("[LREG.4.1] a capture list over something not a match",
        regex_source("    Log e where (a) = e.num > 3\n->\n"
            ++ "    log info \"{a}\"\n"),
        dv_regex_capture_not_match, !T, !IO),
    check_validate_error("[LREG.2.4] a capture list over `!~`",
        regex_source("    Log e where (a) = e.msg !~ /(\\w+)/\n->\n"
            ++ "    log info \"{a}\"\n"),
        dv_regex_capture_not_match, !T, !IO),
    check_validate_error("[LGRA.8.6] a capture nothing reads",
        regex_source("    Log e where (a) = e.msg ~ /(\\w+)/\n->\n"
            ++ "    log info \"x\"\n"),
        dv_unreferenced_binding, !T, !IO),
    check_resolve_error("a capture under a pattern binding's name",
        regex_source("    Log e where (e) = e.msg ~ /(\\w+)/\n->\n"
            ++ "    log info \"{e}\"\n"),
        dv_duplicate_binding, !T, !IO),
    check_validate_error("a capture read before its pattern",
        "schema Log scope logical:\n    k: Int key\n    msg: String mutable\n"
            ++ "schema Dev scope logical:\n    id: String key\n\nrule r:\n"
            ++ "    Dev d where d.id == a\n"
            ++ "    Log e where (a) = e.msg ~ /(\\w+)/\n->\n"
            ++ "    log info \"{a}\"\n",
        dv_unknown_binding, !T, !IO),
    check_validated("[LREG.4.1] a capture joins a later pattern",
        "schema Log scope logical:\n    k: Int key\n    msg: String mutable\n"
            ++ "schema Dev scope logical:\n    id: String key\n\nrule r:\n"
            ++ "    Log e where (a) = e.msg ~ /(\\w+)/\n"
            ++ "    Dev d where d.id == a\n->\n"
            ++ "    log info \"{d.id}\"\n",
        !T, !IO).

    % Correlation keys -- [LRST.1.1], [LCRS.6.2.3], [LRST.1.4] - [LRST.1.5.1].
    %
:- func as_source(string) = string.

as_source(Rhs) =
    "service svc.do:\n    kwarg line: String\n    no response\n\n"
    ++ "schema Req scope logical:\n    entity_id: String key\n"
    ++ "    zone: String? mutable\n    payload: Json mutable\n\n"
    ++ "rule r:\n    Req q\n->\n" ++ Rhs.

:- pred test_as_keys(tally::in, tally::out, io::di, io::uo) is det.

test_as_keys(!T, !IO) :-
    check_parse("[LRST.1.1] `as <expr>` closes a `call` line",
        as_source("    call svc.do line: \"x\" nocooldown as q.entity_id\n"),
        ( pred(F::in) is semidet :-
            list.member(td_rule(R), F ^ f_decls),
            R ^ rd_rhs ^ rr_actions = [A],
            A ^ ac_as = yes(_),
            A ^ ac_args = [_, _]
        ), !T, !IO),
    check_parse("[LCRS.6.2.3] the `as` line closes a `call` block",
        as_source("    call svc.do\n        line: \"x\"\n"
            ++ "        nocooldown\n        as \"k\"\n"),
        ( pred(F::in) is semidet :-
            list.member(td_rule(R), F ^ f_decls),
            R ^ rd_rhs ^ rr_actions = [A],
            A ^ ac_as = yes(ex_string("k", _))
        ), !T, !IO),
    check_parse_fails("[LCRS.6.2.3] a kwarg after `as` is a parse error",
        as_source("    call svc.do as \"k\" line: \"x\"\n"), !T, !IO),
    check_parse_fails("[LCRS.6.2.3] a kwarg line after the `as` line",
        as_source("    call svc.do\n        as \"k\"\n        line: \"x\"\n"),
        !T, !IO),
    check_parse_fails("[LRST.1.1] only `call` takes `as` on its line",
        as_source("    log info \"x\" as \"k\"\n"), !T, !IO),
    check_validated("[LRST.1.4] a String slot key is legal",
        as_source("    call svc.do line: \"x\" nocooldown as q.entity_id\n"),
        !T, !IO),
    check_validated("[LRST.1.5.1] an interpolated key over a key slot is legal",
        as_source("    call svc.do line: \"x\" nocooldown "
            ++ "as \"k-{q.entity_id}\"\n"), !T, !IO),
    check_validate_error("[LRST.1.4] a Json key is refused",
        as_source("    log info \"t\"\n    after 5_min as q.payload:\n"
            ++ "        log info \"x\"\n"),
        dv_as_non_equatable_type, !T, !IO),
    check_validate_error("[LRST.1.5] a Json sub-path key is refused",
        as_source("    log info \"t\"\n    after 5_min as q.payload.f:\n"
            ++ "        log info \"x\"\n"),
        dv_as_softfail_expression, !T, !IO),
    check_validate_error("[LRST.1.5] a nullable slot key is refused",
        as_source("    call svc.do line: \"x\" nocooldown as q.zone\n"),
        dv_nullable_unnarrowed, !T, !IO),
    check_validate_error("[LRST.1.5.1] an interpolated Json sub-path",
        as_source("    call svc.do line: \"x\" nocooldown "
            ++ "as \"k-{q.payload.f}\"\n"),
        dv_as_softfail_expression, !T, !IO),
    check_validate_error("[LRST.1.5.1] an interpolated nullable slot",
        as_source("    call svc.do line: \"x\" nocooldown as \"k-{q.zone}\"\n"),
        dv_as_softfail_expression, !T, !IO),
    check_validate_error("[LGRA.2.9.6.8] an unknown binding in an `as` string",
        as_source("    call svc.do line: \"x\" nocooldown "
            ++ "as \"k-{nope} {q.entity_id}\"\n"),
        dv_unknown_binding, !T, !IO),
    % The positive half, `{error.code}` read in an `error:` body, is in
    % test_encode: it needs the driver's builtin `CallError`, which
    % `check_validated` does not inject.
    check_validate_error("[LCCO.8.2] the body's binding is `error`, not `err`",
        as_source("    call svc.do line: \"x\" nocooldown as \"k\"\n"
            ++ "        error:\n"
            ++ "            log error \"failed: {err.code}\"\n"),
        dv_unknown_binding, !T, !IO),
    check_validate_error("[LCCO.8.2] `error` is not bound outside the body",
        as_source("    log info \"{error.code}\"\n"
            ++ "    call svc.do line: \"x\" nocooldown as \"k\"\n"
            ++ "        error:\n"
            ++ "            log error \"failed\"\n"),
        dv_unknown_binding, !T, !IO).

:- func then_schemas = string.

then_schemas =
    "schema A scope logical:\n    k: Int key\n    ts: Time\n\n"
    ++ "schema B scope logical:\n    k: Int key\n    ts: Time\n\n"
    ++ "schema N scope logical:\n    k: Int key\n\n".

:- pred test_then_followers(tally::in, tally::out, io::di, io::uo) is det.

test_then_followers(!T, !IO) :-
    check_validated("[LTHE.4.8] a `then` line after a positive pattern is fine",
        then_schemas ++ "rule r:\n    A a\n    then B b within 5_s\n->\n"
            ++ "    log info \"{a.k} {b.k}\"\n", !T, !IO),
    check_validate_error("[LTHE.4.8] a `then` line opening the rule",
        then_schemas ++ "rule r:\n    then B b within 5_s\n->\n"
            ++ "    log info \"{b.k}\"\n",
        dv_then_no_predecessor, !T, !IO),
    check_validate_error("[LTHE.4.9] a `then` line under a `no`",
        then_schemas ++ "rule r:\n    no A a\n    then B b within 5_s\n->\n"
            ++ "    log info \"{b.k}\"\n",
        dv_then_after_negation, !T, !IO),
    check_validate_error("[LTHE.5.4] `then latest` is refused",
        then_schemas ++ "rule r:\n    A a\n    then latest B b within 5_s\n"
            ++ "->\n    log info \"{a.k} {b.k}\"\n",
        dv_interior_latest, !T, !IO),
    check_validate_error("[LTHE.5.4] a `latest` sequence below another clause",
        then_schemas ++ "rule r:\n    B x\n    latest A a\n"
            ++ "    then B b within 5_s\n->\n"
            ++ "    log info \"{x.k} {a.k} {b.k}\"\n",
        dv_interior_latest, !T, !IO),
    check_validate_error("[LTHE.4.5] a follower schema with no `ts`",
        then_schemas ++ "rule r:\n    A a\n    then N n within 5_s\n->\n"
            ++ "    log info \"{a.k} {n.k}\"\n",
        dv_within_no_ts_slot, !T, !IO),
    check_validate_error("[LTHE.4.5] an anchor schema with no `ts`",
        then_schemas ++ "rule r:\n    N n then A a within 5_s\n->\n"
            ++ "    log info \"{a.k} {n.k}\"\n",
        dv_within_no_ts_slot, !T, !IO).

    % The `linear_scan: false` refusals at the edges the corpus does not pin:
    % [LNLS.3.10]'s one diagnostic per slot (shared with
    % [LNLS.3.7]), one diagnostic per `Json` path, and no check at all with
    % the capability on.
    %
:- func line_schema = string.

line_schema = "schema Line scope logical:\n    k: Int key\n    text: String mutable\n\n".

:- pred test_nolinscan_refusals(tally::in, tally::out, io::di, io::uo) is det.

test_nolinscan_refusals(!T, !IO) :-
    check_validated_quietly("[LNLS.3.10] with `linear_scan` on, ordering is quiet",
        line_schema ++ "rule r:\n    Line l where l.text < \"m\"\n"
            ++ "->\n    log info \"x\"\n",
        !T, !IO),
    check_validate_codes("[LNLS.3.10] one diagnostic per slot, not per use",
        "use default:\n    linear_scan: false\n\n" ++ line_schema
            ++ "rule r:\n    Line l where l.text < \"m\" and "
            ++ "l.text > \"a\"\n->\n    log info \"x\"\n",
        [dv_nolinscan_unbounded_string_op], !T, !IO),
    check_validate_codes("[LNLS.3.7] a regex takes the slot's one diagnostic",
        "use default:\n    linear_scan: false\n\n" ++ line_schema
            ++ "rule r:\n    Line l where l.text ~ /a/ and "
            ++ "l.text < \"m\"\n->\n    log info \"x\"\n",
        [dv_nolinscan_unbounded_regex], !T, !IO),
    check_validate_codes("[LNLS.3.9] a nested Json path is one diagnostic",
        "use default:\n    linear_scan: false\n\nschema Doc scope logical:\n"
            ++ "    id: Int key\n    j: Json mutable\n\n"
            ++ "rule r:\n    Doc d where d.j.a.b == 1\n->\n    log info \"x\"\n",
        [dv_nolinscan_json_slot, dv_nolinscan_json_path], !T, !IO).

    % [LNLS.3.3]'s anchor check at the edges the conformance fixtures do not
    % reach: the check is scoped to `linear_scan: false`, and a `ttl` pattern is
    % refused once rather than also counted as unanchored.
    %
    % No case for a `no` pattern: [LNLS.3.3] anchors "every positive pattern
    % after the first", and its opening paragraph binds any cross-pattern
    % `where`, as `iret_7_5_1__typed_anchor_decided` reads it.
    %
:- func anchor_schemas = string.

anchor_schemas =
    "schema D scope logical:\n    id: String key\n    level: Int mutable\n\n"
    ++ "schema R scope logical:\n    id: String key\n    amount: Int mutable\n\n"
    ++ "schema P scope ttl 1_min:\n    id: String\n\n".

:- pred test_nolinscan_anchors(tally::in, tally::out, io::di, io::uo) is det.

test_nolinscan_anchors(!T, !IO) :-
    check_validated_quietly("[LNLS.3.3] `linear_scan` on, no anchor needed",
        anchor_schemas ++ "rule r:\n    D d\n    R x where x.amount > d.level\n"
            ++ "->\n    log info \"x\"\n",
        !T, !IO),
    check_validate_codes("[LNLS.3.3c] an unbound later pattern is unanchored",
        "use default:\n    linear_scan: false\n\n" ++ anchor_schemas
            ++ "rule r:\n    D d\n    R\n->\n    log info \"{d.id}\"\n",
        [dv_nolinscan_join_anchor_c], !T, !IO),
    check_validate_codes("[LNLS.3.3c] two bare patterns are a scan, refused",
        "use default:\n    linear_scan: false\n\n" ++ anchor_schemas
            ++ "rule r:\n    D\n    R\n->\n    log info \"x\"\n",
        [dv_nolinscan_join_anchor_c], !T, !IO),
    check_validate_codes("[LNLS.3.3b] a leading `ttl` pattern is refused once",
        "use default:\n    linear_scan: false\n\n" ++ anchor_schemas
            ++ "rule r:\n    P p\n    D d where d.id == p.id\n"
            ++ "->\n    log info \"x\"\n",
        [dv_nolinscan_join_anchor_b], !T, !IO),

    % [LREG.4.8]: under `linear_scan: false` a capture used as a join key is
    % refused with its own code, not as [LNLS.3.3c]'s unanchored pattern. The
    % slot has a `capacity`, so [LNLS.3.7] does not fire on the match.
    check_validate_codes(
        "[LREG.4.8] a capture as a join key is its own refusal, not C",
        "use default:\n    linear_scan: false\n\n" ++ capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Device d where d.id == dev\n"
            ++ "->\n    log info \"{d.id}\"\n",
        [dv_nolinscan_capture_join_key], !T, !IO),
    check_validate_codes("[LREG.4.8] ...and from a `no` pattern too",
        "use default:\n    linear_scan: false\n\n" ++ capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    no Device d where d.id == dev\n"
            ++ "->\n    log info \"{dev}\"\n",
        [dv_nolinscan_capture_join_key], !T, !IO),
    % The twin: with `linear_scan` on, the same join compiles.
    check_validated("[LREG.4.8] with `linear_scan` on, a capture may join",
        capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Device d where d.id == dev\n"
            ++ "->\n    log info \"{d.id}\"\n",
        !T, !IO),
    % "Every other use of a capture is unaffected": read in its own pattern's
    % `where` and in an action, beside a join anchored on `key` slots.
    check_validated(
        "[LREG.4.8] a capture read in its own `where` and an action is no join",
        "use default:\n    linear_scan: false\n\n" ++ capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/"
            ++ " and dev == \"disk\"\n"
            ++ "    Device d where d.id == e.entity_id\n"
            ++ "->\n    log info \"{dev} {d.id}\"\n",
        !T, !IO),
    % A capture in a further constraint on top of a complete anchor is no
    % join key ([LNLS.3.3]'s "additional constraints ... on top of this
    % anchor"): the pattern resolves to at most one
    % fact whatever else its `where` tests.
    check_validated(
        "[LREG.4.8] a capture beside a complete `key` anchor is no join key",
        "use default:\n    linear_scan: false\n\n" ++ capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Device d where d.id == e.entity_id and d.kind == dev\n"
            ++ "->\n    log info \"{d.id}\"\n",
        !T, !IO),
    % A capture equated to a slot that is not `key`, with no anchor, leaves
    % the pattern unanchored: [LNLS.3.3c].
    check_validate_codes(
        "[LREG.4.8] a capture on a non-`key` slot, unanchored, is C",
        "use default:\n    linear_scan: false\n\n" ++ capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Device d where d.kind == dev\n"
            ++ "->\n    log info \"{d.id}\"\n",
        [dv_nolinscan_join_anchor_c], !T, !IO),
    % A composite key: `Bay` keys on (site, slot). With `site` pinned to
    % `e.site` and `slot` to the capture, the capture completes the anchor:
    % exactly [LREG.4.8]'s code.
    check_validate_codes(
        "[LREG.4.8] a capture completing a composite key's anchor",
        "use default:\n    linear_scan: false\n\n" ++ composite_capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Bay b where b.site == e.site and b.slot == dev\n"
            ++ "->\n    log info \"{b.slot}\"\n",
        [dv_nolinscan_capture_join_key], !T, !IO),
    % With `site` pinned to nothing the anchor is incomplete: A beside another
    % equality to the earlier pattern, C with none.
    check_validate_codes(
        "[LNLS.3.3a] a capture on one key slot, the other unpinned, is A",
        "use default:\n    linear_scan: false\n\n" ++ composite_capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Bay b where b.slot == dev and b.note == e.msg\n"
            ++ "->\n    log info \"{b.slot}\"\n",
        [dv_nolinscan_join_anchor_a], !T, !IO),
    check_validate_codes(
        "[LNLS.3.3c] a capture on one key slot and no equality is C",
        "use default:\n    linear_scan: false\n\n" ++ composite_capture_schemas
            ++ "rule r:\n    Event e where (dev) = e.msg ~ /([a-z]+) failed/\n"
            ++ "    Bay b where b.slot == dev\n"
            ++ "->\n    log info \"{b.slot}\"\n",
        [dv_nolinscan_join_anchor_c], !T, !IO).

:- func composite_capture_schemas = string.

composite_capture_schemas =
    "schema Event scope logical:\n    site: String key\n"
    ++ "    msg: String capacity 64 mutable\n\n"
    ++ "schema Bay scope logical:\n    site: String key\n"
    ++ "    slot: String key\n"
    ++ "    note: String capacity 64 mutable\n\n".

:- func capture_schemas = string.

capture_schemas =
    "schema Event scope logical:\n    entity_id: String key\n"
    ++ "    msg: String capacity 64 mutable\n\n"
    ++ "schema Device scope logical:\n    id: String key\n"
    ++ "    kind: String capacity 64 mutable\n\n".

    % Fails validation with exactly `Want`, in order.
    %
:- pred check_validate_codes(string::in, string::in, list(ds_validate)::in,
                             tally::in, tally::out, io::di, io::uo) is det.

check_validate_codes(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_errors(Ds)),
        list.map((pred(D::in, C::out) is semidet :-
            D ^ dg_code = dc_validate(C)), Ds, Codes),
        Codes = Want
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred check_validated(string::in, string::in,
                        tally::in, tally::out, io::di, io::uo) is det.

check_validated(Name, Src, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_ok(_))
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % Compiles with no error and raises `Want` as a warning.
    %
:- pred check_validate_warning(string::in, string::in, ds_validate::in,
                               tally::in, tally::out, io::di, io::uo) is det.

check_validate_warning(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_ok(Ws)),
        list.member(D, Ws),
        D ^ dg_code = dc_validate(Want),
        D ^ dg_severity = sev_warning
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % Compiles with neither an error nor a warning.
    %
:- pred check_validated_quietly(string::in, string::in,
                                tally::in, tally::out, io::di, io::uo) is det.

check_validated_quietly(Name, Src, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_ok([]))
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % `Src`'s own `use` line is refused with `Want` at resolution
    % ([LDIA.3.1]), which `dsc.driver` runs before any validation.
    %
:- pred check_program_refused(string::in, string::in, ds_validate::in,
                              tally::in, tally::out, io::di, io::uo) is det.

check_program_refused(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        Ast ^ af_use = yes(U),
        ldia_3_1_resolve(builtin_registry, U, resolution_refused(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(Want)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred check_validate_error(string::in, string::in, ds_validate::in,
                             tally::in, tally::out, io::di, io::uo) is det.

check_validate_error(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_errors(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(Want)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% Dialect files -- [NDLC.2.1], [NDLC.2.2], [LCAP.3.8]
%-----------------------------------------------------------------------------%

    % A resolved file carrying the settings its own `use` line resolves to,
    % or `default`'s when it has none -- what `dsc.driver` hands `validate`
    % for a program, and what a harness compiling `as_though("default")`
    % does for a test input.
    %
:- func with_settings(resolved_file) = resolved_file.

with_settings(RF) = RF ^ rf_program := Program :-
    ( if RF ^ rf_ast ^ af_use = yes(U0) then
        U = U0
    else
        U = ast_use(ident("default", pos(0, 0)), [], pos(0, 0))
    ),
    ( if ldia_3_1_resolve(builtin_registry, U, resolved(P)) then
        Program = P
    else
        Program = unresolved_program
    ).

    % A dialect file in [NDLC.2.1]'s shape: `call`, `nocooldown` and `regex`
    % on, every other capability off.
    %
:- func call_only_yaml = string.

call_only_yaml = settings_yaml("call_only",
    ["call", "nocooldown", "regex"]).

    % A dialect file setting exactly `On` true and every other capability
    % false.
    %
:- func settings_yaml(string, list(string)) = string.

settings_yaml(Name, On) = "name: " ++ Name ++ "\n" ++ settings_only(On).

    % The `settings` mapping alone, `On` true and every other capability
    % false, for a file whose `name` line is the case under test.
    %
:- func settings_only(list(string)) = string.

settings_only(On) = "settings:\n"
    ++ string.append_list(list.map(
        ( func(C) = "  " ++ capability_name(C) ++ ": "
            ++ ( if list.member(capability_name(C), On) then "true"
                 else "false" ) ++ "\n" ), all_capabilities)).

    % A definition with `On` true and every other capability false, as
    % registration receives it.
    %
:- func def(string, list(string)) = dialect_def.

def(Name, On) = Def :-
    ( if
        read_mapping(settings_yaml(Name, On), yaml_ok(Entries)),
        ndlc_2_1_definition(Entries, definition(Def0))
    then
        Def = Def0
    else
        Def = dialect_def(Name, [])
    ).

:- pred check_yaml_error(string::in, string::in, int::in,
                         tally::in, tally::out, io::di, io::uo) is det.

check_yaml_error(Name, Text, Line, !T, !IO) :-
    read_mapping(Text, Result),
    ( if Result = yaml_error(Line, _) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred check_definition_refused(string::in, string::in,
                                 tally::in, tally::out, io::di, io::uo) is det.

check_definition_refused(Name, Text, !T, !IO) :-
    ( if
        read_mapping(Text, yaml_ok(Entries)),
        ndlc_2_1_definition(Entries, definition_refused(_))
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % [NDLC.6.1]: the file reads as a definition and registration refuses it
    % with DS_VALIDATE_DIALECT_BAD_NAME, read from YAML text.
    %
:- pred check_bad_name(string::in, string::in,
                       tally::in, tally::out, io::di, io::uo) is det.

check_bad_name(Name, Text, !T, !IO) :-
    ( if
        read_mapping(Text, yaml_ok(Entries)),
        ndlc_2_1_definition(Entries, definition(Def)),
        ndlc_2_2_register(Def, builtin_registry,
            registration_refused(dv_dialect_bad_name, _))
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred check_registration_refused(string::in, dialect_def::in,
                                   ds_validate::in,
                                   tally::in, tally::out, io::di, io::uo)
    is det.

check_registration_refused(Name, Def, Want, !T, !IO) :-
    ndlc_2_2_register(Def, builtin_registry, Result),
    ( if Result = registration_refused(Want, _) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

    % A `settings` mapping as registration receives it, `On` true and every
    % other capability false. Registration reads no line number.
    %
:- func lines_of(list(string)) = list(yaml_entry).

lines_of(On) = list.map(
    ( func(C) = yaml_entry(capability_name(C), 0,
        yv_other(( if list.member(capability_name(C), On) then "true"
                   else "false" ))) ),
    all_capabilities).

    % The `validate` codes in `Ds`, in order.
    %
:- func validate_codes(list(diagnostic)) = list(ds_validate).

validate_codes(Ds) = list.filter_map(
    ( func(D) = C is semidet :- D ^ dg_code = dc_validate(C) ), Ds).

    % `Use`, a `use` line with or without its block, resolved over the
    % built-in registry.
    %
:- pred resolved_use(string::in, resolution::out) is semidet.

resolved_use(Use, Result) :-
    built(Use ++ "\nschema S:\n    a: Int\n", Ast),
    Ast ^ af_use = yes(U),
    ldia_3_1_resolve(builtin_registry, U, Result).

:- pred check_use_refused(string::in, string::in, list(ds_validate)::in,
                          tally::in, tally::out, io::di, io::uo) is det.

check_use_refused(Name, Use, Want, !T, !IO) :-
    ( if
        resolved_use(Use, resolution_refused(Ds)),
        validate_codes(Ds) = Want
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % Validates `Src` under `Use` -- a `use` line, with or without its block --
    % over the built-in registry plus `call_only`, as `dsc.driver` does:
    % resolve the line, then validate the module under what it resolved to.
    %
:- pred validated_under(string::in, string::in, validate_result::out)
    is semidet.

validated_under(Use, Src, Result) :-
    read_mapping(call_only_yaml, yaml_ok(Entries)),
    ndlc_2_1_definition(Entries, definition(Def)),
    ndlc_2_2_register(Def, builtin_registry, registered(Registry)),
    built(Use ++ "\n\n" ++ Src, Ast),
    Ast ^ af_use = yes(U),
    ldia_3_1_resolve(Registry, U, resolved(Program)),
    resolve_file(Ast, resolve_ok(RF)),
    validate_file(RF ^ rf_program := Program, Result).

    % Refused under `Use` with `DS_VALIDATE_CAPABILITY_DISABLED`, and the
    % message carries `Says` ([LDIA.5.3]'s "where its setting came from").
    %
:- pred check_disabled(string::in, string::in, string::in, string::in,
                       tally::in, tally::out, io::di, io::uo) is det.

check_disabled(Name, Use, Src, Says, !T, !IO) :-
    ( if
        validated_under(Use, Src, validate_errors(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(dv_capability_disabled),
        string.sub_string_search(D ^ dg_message, Says, _)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO),
    % A failure prints what the refusal said.
    ( if Ok = no then
        ( if validated_under(Use, Src, Got) then
            (
                Got = validate_ok(_),
                io.write_string("    got: validated\n", !IO)
            ;
                Got = validate_errors(Errs),
                list.foldl(
                    ( pred(E::in, !.IO::di, !:IO::uo) is det :-
                        io.write_string("    got: " ++ E ^ dg_message ++ "\n",
                            !IO)
                    ), Errs, !IO)
            )
        else
            io.write_string("    got: no resolved program\n", !IO)
        )
    else
        true
    ).

:- pred check_admitted(string::in, string::in, string::in,
                       tally::in, tally::out, io::di, io::uo) is det.

check_admitted(Name, Use, Src, !T, !IO) :-
    ( if validated_under(Use, Src, validate_ok(_)) then Ok = yes
    else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred test_dialect_files(tally::in, tally::out, io::di, io::uo) is det.

test_dialect_files(!T, !IO) :-
    % ── the YAML subset ────────────────────────────────────────────────────
    check("[NDLC.2.1] a dialect file reads as `name` and one nested mapping",
        ( if
            read_mapping(call_only_yaml, yaml_ok(Entries)),
            Entries = [yaml_entry("name", 1, yv_string("call_only")),
                yaml_entry("settings", 2, yv_map(Settings))],
            list.same_length(Settings, all_capabilities),
            Settings = [yaml_entry("realtime", 3, yv_other("false")) | _],
            list.member(yaml_entry("call", _, yv_other("true")), Settings)
        then yes else no ), !T, !IO),
    check("a flow list, a trailing comment and a document marker",
        ( if
            read_mapping("---\nname: x   # the name\nenabled_forms: []\n"
                ++ "disabled_forms: [call, publish]\n", yaml_ok(Entries2)),
            Entries2 = [yaml_entry("name", 2, yv_string("x")),
                yaml_entry("enabled_forms", 3, yv_list([])),
                yaml_entry("disabled_forms", 4,
                    yv_list([yv_string("call"), yv_string("publish")]))]
        then yes else no ), !T, !IO),
    % `on` is a boolean to PyYAML, not a string; `key:` with nothing under it
    % is null.
    check("`- on` is not a string, and an empty `key:` is null",
        ( if
            read_mapping("a:\n  - on\nb:\n", yaml_ok(Entries3)),
            Entries3 = [yaml_entry("a", 1, yv_list([yv_other("on")])),
                yaml_entry("b", 3, yv_null)]
        then yes else no ), !T, !IO),
    check("a quoted scalar keeps its text",
        ( if
            read_mapping("name: \"on\"\n", yaml_ok(Entries4)),
            Entries4 = [yaml_entry("name", 1, yv_string("on"))]
        then yes else no ), !T, !IO),
    check_yaml_error("a tab in the indentation is refused on its line",
        "a:\n\t- x\n", 2, !T, !IO),
    % One level of nesting; a second is refused on the line that opens it.
    check_yaml_error("a mapping nested two deep is refused, not skipped",
        "name: x\nsettings:\n  inner:\n    call: true\n", 3, !T, !IO),
    check_yaml_error("lines of one mapping at two indentations",
        "settings:\n  call: true\n    publish: false\n", 3, !T, !IO),
    check_yaml_error("a key given twice inside the mapping",
        "settings:\n  call: true\n  call: false\n", 3, !T, !IO),
    check_yaml_error("a `- item` among the mapping's lines",
        "settings:\n  call: true\n  - publish\n", 3, !T, !IO),
    check_yaml_error("a key given twice is refused where PyYAML keeps one",
        "name: x\nname: y\n", 2, !T, !IO),
    check_yaml_error("an item with no key above it",
        "- call\n", 1, !T, !IO),
    check_yaml_error("an escape inside double quotes",
        "name: \"a\\nb\"\n", 1, !T, !IO),
    check_yaml_error("a block scalar",
        "description: |\n  text\n", 1, !T, !IO),
    check_yaml_error("items of one list at two indentations",
        "a:\n  - x\n    - y\n", 3, !T, !IO),

    % ── the file's fields -- [NDLC.2.1] ─────────────────────────────────────
    check_definition_refused("[NDLC.2.1] `settings` is required",
        "name: x\n", !T, !IO),
    check_definition_refused("`settings` as a list is refused",
        "name: x\nsettings:\n  - call\n", !T, !IO),
    % `enabled_forms` is refused by name, not read as an empty dialect.
    check_definition_refused("[NDLC.2.1] form lists are refused",
        "name: x\nenabled_forms: []\ndisabled_forms: []\n", !T, !IO),
    % [NDLC.2.1] lists two fields; a third is refused, `description` included.
    check_definition_refused("an unknown key is refused, not ignored",
        "name: x\ndescription: a tier\nsettings:\n  call: true\n", !T, !IO),

    % ── registration, in [NDLC.6.1]'s order ────────────────────────────────
    check("[NDLC.2.2] `call_only` registers with exactly its three settings",
        ( if
            read_mapping(call_only_yaml, yaml_ok(Entries6)),
            ndlc_2_1_definition(Entries6, definition(Def6)),
            ndlc_2_2_register(Def6, builtin_registry, registered(Reg6)),
            map.search(Reg6, "call_only", CO),
            ascending(CO ^ dl_settings) = [cap_regex, cap_call, cap_nocooldown]
        then yes else no ), !T, !IO),
    check_registration_refused("[NDLC.2.2] a key naming no capability",
        dialect_def("x", lines_of(["call"])
            ++ [yaml_entry("nolinscan", 0, yv_other("true"))]),
        dv_dialect_unknown_capability, !T, !IO),
    check_registration_refused("[NDLC.2.2] a capability left unset",
        dialect_def("x", list.filter(
            ( pred(E::in) is semidet :- E ^ ye_key \= "regex" ),
            lines_of(["call"]))),
        dv_dialect_incomplete, !T, !IO),
    % [NDLC.2.1] writes `true` and `false`; a capability given anything else,
    % `on` included, is unset.
    check_registration_refused("[NDLC.2.2] a setting that is not true/false",
        dialect_def("x", list.map(
            ( func(E) = ( if E ^ ye_key = "call"
                          then E ^ ye_value := yv_other("on") else E ) ),
            lines_of(["call"]))),
        dv_dialect_incomplete, !T, !IO),
    % [NDLC.6.1]'s order: an unknown capability is named before a missing one.
    check_registration_refused("[NDLC.6.1] an unknown key outranks a gap",
        dialect_def("x", list.filter(
            ( pred(E::in) is semidet :- E ^ ye_key \= "regex" ),
            lines_of(["call"]))
            ++ [yaml_entry("nolinscan", 0, yv_other("true"))]),
        dv_dialect_unknown_capability, !T, !IO),
    check_registration_refused("[LCAP.3.8] `nocooldown` without `call`",
        def("x", ["nocooldown"]), dv_dialect_dependency, !T, !IO),
    check_registration_refused("[LCAP.3.8] `persist_on_series` alone",
        def("x", ["persist_on_series"]), dv_dialect_dependency, !T, !IO),
    check_registration_refused("[LCAP.3.8] `realtime` without `constspace`",
        def("x", ["realtime"]), dv_dialect_dependency, !T, !IO),
    check_registration_refused("a built-in name cannot be replaced",
        def("default", ["call"]), dv_dialect_duplicate_name, !T, !IO),
    % [NDLC.6.1]'s bad names: no `use` line could name the dialect. Every
    % file's settings are otherwise valid (all `false`).
    check_bad_name("[NDLC.6.1] a missing `name` is 1201",
        settings_only([]), !T, !IO),
    check_bad_name("[NDLC.6.1] an empty `name` is 1201",
        "name: \"\"\n" ++ settings_only([]), !T, !IO),
    check_bad_name("[NDLC.6.1] `name: \"a b\"` is two names, 1201",
        "name: \"a b\"\n" ++ settings_only([]), !T, !IO),
    check_bad_name("[NDLC.6.1] `name: 9x` is not a name, 1201",
        "name: 9x\n" ++ settings_only([]), !T, !IO),
    check_bad_name("[NDLC.6.1] `name: 123` is a number, 1201",
        "name: 123\n" ++ settings_only([]), !T, !IO),
    % The same file under a one-word name registers.
    check("[NDLC.6.1] a one-identifier name registers",
        ( if
            read_mapping("name: plain_one\n" ++ settings_only([]),
                yaml_ok(EntriesN)),
            ndlc_2_1_definition(EntriesN, definition(DefN)),
            ndlc_2_2_register(DefN, builtin_registry, registered(RegN)),
            map.contains(RegN, "plain_one")
        then yes else no ), !T, !IO),
    % `realtime` does not require `linear_scan: false`. The dialect is
    % refused as deferred ([LCAP.2.1.5]), and the constraints are checked
    % first, so no [LCAP.3.8] constraint fired.
    check_registration_refused("[LCAP.3.8] `realtime` with `linear_scan` on",
        def("rt", ["realtime", "constspace", "linear_scan"]),
        dv_realtime_deferred, !T, !IO),
    check_registration_refused("[LCAP.2.1.5] a dialect setting `constspace`",
        def("cs", ["constspace"]), dv_realtime_deferred, !T, !IO),
    % [LCAP.2.10], [NDLC.6.1]: a storage or samples-plane capability set
    % `true` is refused at registration, 1222. `call` is on in the first, so
    % no [LCAP.3.8] constraint fires ahead of it.
    check_registration_refused("[LCAP.2.10] a dialect setting `sampled_slots`",
        def("ss", ["sampled_slots"]), dv_capability_deferred, !T, !IO),
    check_registration_refused(
        "[LCAP.2.10] a dialect setting `storage_hydrate_facts` with `call`",
        def("sl", ["call", "storage_hydrate_facts"]), dv_capability_deferred,
        !T, !IO),
    % [LDIA.3.3.2], [NDLC.6.1]: a name that is no capability is refused
    % ahead of the member the file then lacks.
    check_registration_refused(
        "[LDIA.3.3.2] a dialect spelling `storage_hydrate_events`",
        dialect_def("old", list.filter(
            ( pred(E::in) is semidet :- E ^ ye_key \= "storage_hydrate_facts" ),
            lines_of(["call"]))
            ++ [yaml_entry("storage_hydrate_events", 0, yv_other("false"))]),
        dv_dialect_unknown_capability, !T, !IO),
    check_registration_refused(
        "[LDIA.3.3.2] a dialect spelling `storage_event_query`",
        dialect_def("old", lines_of(["call"])
            ++ [yaml_entry("storage_event_query", 0, yv_other("false"))]),
        dv_dialect_unknown_capability, !T, !IO),
    % [NDLC.2.4]: every write and every call off, and what depends on `call`
    % with it, is a valid read-only dialect.
    check("[NDLC.2.4] a read-only dialect registers",
        ( if
            ndlc_2_2_register(def("ro", ["linear_scan", "logical", "regex",
                "float", "series"]),
                builtin_registry, registered(_))
        then yes else no ), !T, !IO),

    % ── the built-ins -- [LDIA.9]──────────────────────────────────────────
    check("[LDIA.9.2] `default` is the table: seven capabilities off",
        ( if
            resolved_use("use default", resolved(P1)),
            not enabled(P1, cap_realtime),
            not enabled(P1, cap_constspace),
            not enabled(P1, cap_dynamic_ttl),
            not enabled(P1, cap_sampled_slots),
            not enabled(P1, cap_persist_on_series),
            not enabled(P1, cap_storage_hydrate_facts),
            not enabled(P1, cap_storage_hydrate_samples),
            enabled(P1, cap_linear_scan),
            enabled(P1, cap_float),
            enabled(P1, cap_series)
        then yes else no ), !T, !IO),
    % Read from the registry: [LDIA.3.2.3] refuses `use realtime` at the
    % name, and the dialect stays registered with [LDIA.9]'s table.
    check("[LDIA.9] `realtime` is `default` plus `realtime` and `constspace`",
        ( if
            map.search(builtin_registry, "realtime", RtDialect),
            set.contains(RtDialect ^ dl_settings, cap_realtime),
            set.contains(RtDialect ^ dl_settings, cap_constspace),
            set.contains(RtDialect ^ dl_settings, cap_linear_scan)
        then yes else no ), !T, !IO),
    check("[LDIA.9] `base` sets every capability false",
        ( if
            resolved_use("use base", resolved(P3)),
            set.is_empty(P3 ^ ps_enabled)
        then yes else no ), !T, !IO),

    % ── the `use` block -- [LDIA.3] ────────────────────────────────────────
    check("[LDIA.3.3.1] a line overrides the dialect, and is remembered",
        ( if
            resolved_use("use default:\n    regex: false", resolved(P4)),
            not enabled(P4, cap_regex),
            enabled(P4, cap_call),
            map.search(P4 ^ ps_lines, cap_regex, 2)
        then yes else no ), !T, !IO),
    check_use_refused("[LDIA.3.2.2] an unknown dialect",
        "use nowhere", [dv_unknown_dialect], !T, !IO),
    check_use_refused("[LDIA.3.3.2] an unknown capability",
        "use default:\n    nolinscan: true", [dv_unknown_capability], !T, !IO),
    check_use_refused("[LDIA.3.3.6] a capability set twice",
        "use default:\n    regex: true\n    regex: false",
        [dv_capability_duplicate], !T, !IO),
    % Every bad line is reported.
    check_use_refused("[LDIA.3.3] two bad lines, two diagnostics",
        "use default:\n    bogus: true\n    regex: true\n    regex: false",
        [dv_unknown_capability, dv_capability_duplicate], !T, !IO),
    % Nothing is switched on to satisfy a constraint ([LDIA.3.5.1]).
    % `nocooldown` is `default`'s and needs `call`: one violation.
    check_use_refused("[LDIA.3.5.1] `nocooldown` with `call` off",
        "use default:\n    call: false", [dv_capability_constraint],
        !T, !IO),
    % [LDIA.3.3.7]: a deferred setting is refused before the constraints.
    check_use_refused("[LDIA.3.3.7] `realtime: true` without `constspace`",
        "use default:\n    realtime: true", [dv_realtime_deferred],
        !T, !IO),
    check_use_refused("[LDIA.3.3.7] `constspace: true`",
        "use default:\n    constspace: true", [dv_realtime_deferred],
        !T, !IO),
    check("[LDIA.3.3.7] lines setting both deferred capabilities `false`",
        ( if
            resolved_use("use default:\n    realtime: false\n"
                ++ "    constspace: false", resolved(_))
        then yes else no ), !T, !IO),
    % [LCAP.2.10]: the storage and samples-plane capabilities are refused the
    % same way, with DS_VALIDATE_CAPABILITY_DEFERRED, before the constraints.
    check_use_refused("[LCAP.2.10] `sampled_slots: true`",
        "use default:\n    sampled_slots: true", [dv_capability_deferred],
        !T, !IO),
    check_use_refused("[LCAP.2.10] deferred before the constraints",
        "use default:\n    call: false\n    storage_hydrate_facts: true",
        [dv_capability_deferred], !T, !IO),
    check_use_refused("[LCAP.2.10] both kinds of deferral, each its code",
        "use default:\n    realtime: true\n    sampled_slots: true",
        [dv_realtime_deferred, dv_capability_deferred], !T, !IO),
    check("[LCAP.2.10] lines setting the four `false` resolve",
        ( if
            resolved_use("use default:\n    sampled_slots: false\n"
                ++ "    persist_on_series: false\n"
                ++ "    storage_hydrate_facts: false\n"
                ++ "    storage_hydrate_samples: false", resolved(_))
        then yes else no ), !T, !IO),
    % [LDIA.3.3.2]: these name no capability, whatever value the line gives
    % them. One diagnostic per line.
    check_use_refused("[LDIA.3.3.2] `storage_hydrate_events`",
        "use default:\n    storage_hydrate_events: false",
        [dv_unknown_capability], !T, !IO),
    check_use_refused("[LDIA.3.3.2] three storage-query names",
        "use default:\n    storage_sample_latest: false\n"
            ++ "    storage_sample_agg: false\n"
            ++ "    storage_event_query: false",
        [dv_unknown_capability, dv_unknown_capability,
         dv_unknown_capability], !T, !IO),
    % [LDIA.3.2.3]: the `realtime` dialect is refused at its name, whatever
    % the block overrides -- here the overrides leave `default`'s settings.
    check_use_refused("[LDIA.3.2.3] `use realtime`",
        "use realtime", [dv_realtime_deferred], !T, !IO),
    check_use_refused("[LDIA.3.2.3] `use realtime` with both turned off",
        "use realtime:\n    realtime: false\n    constspace: false",
        [dv_realtime_deferred], !T, !IO),
    check_use_refused("[LDIA.3.2.3] the name before any line is read",
        "use realtime:\n    bogus: true", [dv_realtime_deferred], !T, !IO),
    % [LDIA.3.1]: the steps stop at the first that fails.
    check_use_refused("[LDIA.3.1] a bad override stops before the constraints",
        "use default:\n    realtime: true\n    bogus: true",
        [dv_unknown_capability], !T, !IO),

    % ── per-construct gating -- [LDIA.3.4], [LDIA.5] ──────────────────────
    CallSrc = "service svc.method:\n    \"\"\"stub\"\"\"\n    no response\n\n"
        ++ "schema Trig:\n    v: Int\n\n"
        ++ "rule r:\n    Trig\n->\n    call svc.method nocooldown\n",
    PublishSrc = "schema Trig:\n    v: Int\n\n"
        ++ "schema Local:\n    a: Int\n\n"
        ++ "rule r:\n    Trig\n->\n    publish Local a: 1\n",
    check_admitted("a registered dialect admits what it sets true",
        "use call_only", CallSrc, !T, !IO),
    check_disabled("[LDIA.5.3] and refuses what it sets false, naming it",
        "use call_only", PublishSrc, "dialect `call_only`", !T, !IO),
    check_admitted("[LDIA.3.3.1] a block line turns a capability on",
        "use call_only:\n    publish: true", PublishSrc, !T, !IO),
    % Not `call: false` under `default`, which keeps `nocooldown`
    % ([LCAP.3.8]): that block is refused at the constraints.
    check_disabled("[LDIA.5.3] a block line's refusal names the line",
        "use default:\n    publish: false", PublishSrc, "line 2", !T, !IO),
    check_admitted("[LDIA.9] `base` admits a program using no capability",
        "use base", "schema S:\n    a: Int\n", !T, !IO),
    check_disabled("[LNOG.3.1] `logical: false` refuses a `logical` schema",
        "use default:\n    logical: false",
        "schema S scope logical:\n    k: Int key\n", "`logical`", !T, !IO),
    FloatOff = "use default:\n    float: false",
    check_disabled("[LCAP.2.9] `float: false` refuses a `Float` slot",
        FloatOff, "schema S:\n    a: Float\n", "`float`", !T, !IO),
    check_disabled("[LCAP.2.9] and `/`, which always produces a `Float`",
        FloatOff, "schema S:\n    a: Int\n\nrule r:\n    S s where s.a / 2 > 1"
            ++ "\n->\n    log info \"{s.a}\"\n", "`float`", !T, !IO),
    check_admitted("[LCAP.2.9] but `//` on `Int`s is not a `Float`",
        FloatOff, "schema S:\n    a: Int\n\nrule r:\n    S s where s.a // 2 > 1"
            ++ "\n->\n    log info \"{s.a}\"\n", !T, !IO).

%-----------------------------------------------------------------------------%
% Companion slots -- [LSER.6]
%-----------------------------------------------------------------------------%
%
% The resolution order: a declared slot beats an aggregation name, a labelled
% line takes away the unlabelled form, and a slot designator is read before a
% label.

:- pred test_companion(tally::in, tally::out, io::di, io::uo) is det.

test_companion(!T, !IO) :-
    % `use default`, whose `series` is `true` ([LDIA.9.2]).
    Schema = "use default\n\nschema Sensor scope logical:\n" ++
        "    entity_id: String key\n    val: Float mutable\n" ++
        "    other: Float mutable\n    ts: Time\n",
    Rule = ( func(Guard) = Schema ++ "series Sensor.val:\n    mean sliding "
        ++ "10_min\n\nrule r:\n    Sensor s where " ++ Guard
        ++ "\n->\n    log info \"m\"\n" ),

    check_validated("[LSER.6.2] `t.mean` resolves to the declared observation",
        Rule("s.mean > 0.0"), !T, !IO),

    % [LSER.6.11.1] step 1 with a slot designator present.
    check_validated("[LSER.6.9.6] the slot designator resolves the same read",
        Rule("s.val.mean > 0.0"), !T, !IO),

    check_validate_error("[LSER.6.9.4] an undeclared aggregation is named",
        Rule("s.stdev > 0.0"), dv_no_series_for_companion_slot, !T, !IO),

    % ── cold reads -- [LSER.19.8] ─────────────────────────────────────────
    %
    % The anomaly guard below is [LSER.8.6.2]'s own line.
    Cold = ( func(Body) = Schema ++ "\nschema Out scope logical:\n"
        ++ "    k: String key\n    avg: Float mutable\n    n: Int mutable\n"
        ++ "series Sensor.val:\n    mean sliding 10_min\n"
        ++ "    stdev sliding 10_min\n    count sliding 10_min\n\n"
        ++ "rule r:\n    Sensor s\n->\n" ++ Body ),

    check_validate_error("[LSER.19.8] a cold-null `stdev` into a concrete slot",
        Cold("    emit Out logical k: \"x\" avg: s.stdev n: 0\n"),
        dv_nullable_unnarrowed, !T, !IO),

    check_validate_error("[LSER.19.8] and the call form types the same",
        Cold("    emit Out logical k: \"x\" avg: mean(s.val) n: 0\n"),
        dv_nullable_unnarrowed, !T, !IO),

    check_validated("[LSER.19.8] `count` keeps a concrete `Int`",
        Cold("    emit Out logical k: \"x\" avg: 0.0 n: count(s.val)\n"),
        !T, !IO),

    % [LSER.16.1]: the call and companion forms are one read, and
    % [LSER.17.2] gives them one static type.
    check_validated("[LSER.16.1] the companion form of `count` too",
        Cold("    emit Out logical k: \"x\" avg: 0.0 n: s.count\n"),
        !T, !IO),

    check_validated("[LSER.8.6.2] the anomaly guard compiles and propagates",
        Schema ++ "series Sensor.val:\n    mean sliding 10_min\n"
            ++ "    stdev sliding 10_min\n\nrule r:\n    Sensor s where "
            ++ "s.val - s.mean > 2.0 * s.stdev\n->\n    log info \"m\"\n",
        !T, !IO),

    % ── return types -- [LSER.17.2] ───────────────────────────────────────
    %
    % `mean` of an `Int` slot is a `Float`; `min` of one is an `Int`. Bitwise
    % `&` takes integers only ([LEXP.7.7]), so it shows which leaf each has.
    IntSeries = ( func(Guard) = "use default\n\n"
        ++ "schema Counter scope logical:\n    entity_id: String key\n"
        ++ "    n: Int mutable\n\nseries Counter.n:\n    mean sliding 10_min\n"
        ++ "    min sliding 10_min\n    direction sliding 10_s\n"
        ++ "    count_of sliding 10_min\n\n"
        ++ "rule r:\n    Counter c where " ++ Guard
        ++ "\n->\n    log info \"m\"\n" ),

    check_validate_error("[LSER.17.2] `mean` of an `Int` slot is a `Float`",
        IntSeries("c.mean & 1 > 0"), dv_bitwise_type, !T, !IO),

    check_validated("[LSER.17.2] but `min` of one is an `Int`",
        IntSeries("c.min & 1 > 0"), !T, !IO),

    check_validate_error("[LSER.17.2] `direction` is an `Int?`",
        IntSeries("c.direction == \"rising\""), dv_type_mismatch, !T, !IO),

    check_validate_error("[LSER.17.2] `count_of` is an `Int`",
        IntSeries("count_of(c.n, 3) == \"3\""), dv_type_mismatch, !T, !IO),

    % The slot designator restricts: `mean` is declared on `val`, not `other`.
    check_validate_error("[LSER.6.11.1] and the designator restricts the search",
        Rule("s.other.mean > 0.0"), dv_no_series_for_companion_slot, !T, !IO),

    % ── labels ─────────────────────────────────────────────────────────────

    Labelled = ( func(Guard) = Schema ++ "series Sensor.val:\n"
        ++ "    mean sliding 10_min as recent\n"
        ++ "    mean sliding 1_h as hourly\n\nrule r:\n    Sensor s where "
        ++ Guard ++ "\n->\n    log info \"m\"\n" ),

    check_validated("[LSER.6.8.1] a labelled line is read through its label",
        Labelled("s.recent.mean > 0.0"), !T, !IO),

    % [LSER.6.8.5]: a labelled line produces no unlabelled companion form, so
    % `s.mean` does not resolve, rather than being ambiguous.
    check_validate_error("[LSER.6.8.5] a labelled line has no `t.<agg>`",
        Labelled("s.mean > 0.0"), dv_no_series_for_companion_slot, !T, !IO),

    check_validate_error("[LSER.6.8.4] an unknown label is refused",
        Labelled("s.bogus.mean > 0.0"), dv_no_series_for_companion_slot,
        !T, !IO),

    % ── cross-slot ambiguity ───────────────────────────────────────────────

    TwoSlots = Schema ++ "series Sensor.val:\n    mean sliding 10_min\n"
        ++ "series Sensor.other:\n    mean sliding 10_min\n"
        ++ "rule r:\n    Sensor s where s.mean > 0.0\n->\n    log info \"m\"\n",

    check_validate_error("[LSER.6.9.3] two slots declaring `mean` is ambiguous",
        TwoSlots, dv_ambiguous_companion_slot, !T, !IO),

    % ── a slot named for an aggregation ───────────────────────────────────
    %
    % [LSER.6.6.1], [LLEX.9.5]: the `pXX` family is reserved, so the
    % declaration is refused.
    check_validate_error("[LLEX.9.5] a `p1` slot is refused, series or not",
        "schema Edge scope explicit:\n    p1: Int\n    p2: Int\n",
        dv_companion_slot_collision, !T, !IO),

    % ── the expression form -- [LSER.16.1], [LSER.10.6] ────────────────────

    check_validated("[LSER.16.1] `mean(s)` resolves like `s.mean`",
        Rule("mean(s) > 0.0"), !T, !IO),

    check_validate_error("[LSER.6.7.1] and refuses where `s.mean` refuses",
        Schema ++ "rule r:\n    Sensor s where mean(s) > 0.0\n->\n"
            ++ "    log info \"m\"\n",
        dv_no_series_for_companion_slot, !T, !IO),

    % [LSER.6.8.1]: the labelled companion and expression forms are one read.
    check_validated("[LSER.6.8.1] a labelled cursor in call position",
        Labelled("mean(s.recent) > 0.0"), !T, !IO),

    check_validated("[LSER.6.10.2] and a slot-designator cursor",
        Rule("mean(s.val) > 0.0"), !T, !IO),

    % `min` / `max` are both scalar builtins and aggregations; [LSER.16]
    % resolves them by argument type.
    check_validated("[LSER.16] scalar `max` over two slot reads still types",
        Rule("max(s.val, s.other) > 0.0"), !T, !IO),

    % [LUNI.9.1]: "Return the same unit as the series field."
    Dimensioned = ( func(Guard) =
        "use default\n\n"
            ++ "unit dimension warmth storage float64 base therm\n"
            ++ "unit therm: warmth\n"
            ++ "unit dimension heft storage float64 base lump\n"
            ++ "unit lump: heft\n"
            ++ "schema Reading scope logical:\n    entity_id: String key\n"
            ++ "    temp: therm mutable\n"
            ++ "series Reading.temp:\n    mean sliding 10_min\n"
            ++ "rule r:\n    Reading r where " ++ Guard
            ++ "\n->\n    log info \"m\"\n" ),

    % Observed through arithmetic, where [LUNI.8.2] states the cross-dimension
    % error.
    check_validated("[LUNI.9.1] `mean` keeps the slot's dimension",
        Dimensioned("(mean(r.temp) + 1_therm) > 0_therm"), !T, !IO),

    check_validate_error("[LUNI.8.2] so adding a heft to it is a mismatch",
        Dimensioned("(mean(r.temp) + 1_lump) > 0.0"),
        dv_dim_mismatch, !T, !IO),

    % [LSER.10.6]: "companion-slot form and expression form are fully
    % equivalent".
    check_validate_error("[LSER.10.6] the companion form agrees",
        Dimensioned("(r.mean + 1_lump) > 0.0"), dv_dim_mismatch, !T, !IO),

    % ── applicability -- [LSER.17.7]'s two axes ────────────────────────────

    Decl = ( func(Slot, Line) =
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    val: Float mutable\n    tag: String mutable\n"
            ++ "    active: Bool mutable\n"
            ++ "series Sensor." ++ Slot ++ ":\n    " ++ Line ++ "\n" ),

    check_validated("[LSER.18.1] `mean sliding` is backed",
        Decl("val","mean sliding 10_min"), !T, !IO),

    % [LSER.18.1]'s two ✗ codes: `last tumbling` is ✗ § (no backend), and
    % `bool_and sample` is a bare ✗ (no meaning).
    check_validate_error("[LSER.18.1] § `last tumbling` has no exact backing",
        Decl("val","last tumbling 10_min"),
        dv_series_no_exact_backing, !T, !IO),

    check_validate_error("[LSER.18.1] but `bool_and sample` has no meaning",
        Decl("active", "bool_and sample 200"),
        dv_series_agg_time_model_mismatch, !T, !IO),

    % † and ‡: the quantiles and the equality-keyed aggregations need a
    % bounded window.
    check_validate_error("[LSER.18.1] † `p95 all_time` needs a bounded window",
        Decl("val","p95 all_time"), dv_series_no_exact_backing, !T, !IO),

    check_validate_error("[LSER.18.1] ‡ and so does `count_distinct all_time`",
        Decl("val","count_distinct all_time"),
        dv_series_no_exact_backing, !T, !IO),

    % [LSER.14.4.5]: no aggregation is backed on `tumbling`, `first` and
    % `integral` included.
    check_validate_error("[LSER.14.4.5] `first tumbling` is refused",
        Decl("val","first tumbling 10_min"),
        dv_series_no_exact_backing, !T, !IO),

    check_validate_error("[LSER.14.4.5] `integral tumbling` is refused",
        Decl("val","integral tumbling 10_min"),
        dv_series_no_exact_backing, !T, !IO),

    check_validate_error("[LSER.17.2] `mean` does not apply to a String slot",
        Decl("tag", "mean sliding 10_min"),
        dv_series_agg_type_mismatch, !T, !IO),

    % [LSER.17.7]: "the compiler reports the first failing axis", and type is
    % first. `active_fraction` admits only `sliding` ([LSIG.1.3.3]), so this
    % fails both axes, and the type is named.
    check_validate_error("[LSER.17.7] the type axis is reported first",
        Decl("val","active_fraction tumbling 5_min"),
        dv_series_agg_type_mismatch, !T, !IO),

    check_validate_error("[LSIG.1.3.3] and the model axis when type passes",
        Decl("active", "active_fraction tumbling 5_min"),
        dv_series_agg_time_model_mismatch, !T, !IO),

    check_validate_error("[LSER.17.6] `p0` is not a legal quantile",
        Decl("val","p0 sliding 10_min"),
        dv_series_invalid_quantile, !T, !IO),

    % [LSER.6.5] withholds `count_of` from `t.count_of`, not from the
    % declaration.
    check_validated("[LSER.6.5] `count_of` is legal in a declaration",
        Decl("tag", "count_of sliding 10_min"), !T, !IO),

    % ── dwell -- [LSER.10.4] ───────────────────────────────────────────────

    check_validated("[LSER.10.4] `t.dwell` needs no series declaration",
        Schema ++ "rule r:\n    Sensor s where s.dwell > 60_s\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    % [LEXP.9.5.1], [LUNI.8.3]: a dwell is a `Duration`, and a bare number
    % beside one is refused.
    check_validate_error("[LUNI.8.3] a dwell against a bare number",
        Schema ++ "rule r:\n    Sensor s where s.dwell > 60\n->\n"
            ++ "    log info \"m\"\n", dv_dim_mismatch, !T, !IO),

    % [LEXP.9.5.1]: `dwell` reads the entry stamp and no slot, so a schema
    % with no `ts` carries one.
    check_validated("[LEXP.9.5.1] nor a `ts` slot",
        "schema Bare scope logical:\n    state: Float key\n"
            ++ "rule r:\n    Bare b where b.dwell > 60_s\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    check_validate_error("[LFAC.1.4.2] and a `logical` binding",
        "schema Evt scope ttl 1_min:\n    code: String\n    ts: Time\n"
            ++ "rule r:\n    Evt e where e.dwell > 60\n->\n"
            ++ "    log info \"m\"\n", dv_dwell_ttl_schema, !T, !IO).

    % A rules file importing the first library, against the given sources.
    %
    %@helper
:- pred check_cycle_path(string::in, list(pair(string, string))::in,
                         string::in, tally::in, tally::out,
                         io::di, io::uo) is det.

check_cycle_path(Name, Sources, Want, !T, !IO) :-
    ( if
        Sources = [Entry - _ | _],
        built("import " ++ Entry ++ "\n", Ast),
        load_libraries(map.from_assoc_list(Sources), Ast ^ af_decls, _, Ds),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(dv_import_cycle),
        string.sub_string_search(D ^ dg_message, Want, _)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % `check_validate_error`'s sibling for the `ds_front` namespace.
    %
    % A `validate` check can carry a front-end code: [LGRA.6.6.7]'s
    % duplicate-modifier rule is the compiler's ([LCDB.7.8]), and the corpus
    % names it `DS_PARSE_DUP_RATE_MOD`.
    %
:- pred check_front_error(string::in, string::in, ds_front::in,
                          tally::in, tally::out, io::di, io::uo) is det.

check_front_error(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_ok(RF)),
        validate_file(with_settings(RF), validate_errors(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_front(Want)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_validate(tally::in, tally::out, io::di, io::uo) is det.

test_validate(!T, !IO) :-
    % `specs/conformance/compiler/LIMP.2.3.2.json`, verbatim.
    check_validate_error("[LIMP.2.3.2] an import after a declaration",
        "schema Trig scope logical:\n    v: Int key\n\nimport some_lib\n",
        dv_import_after_decl, !T, !IO),

    % `specs/conformance/compiler/LIMP.2.3.3.json`, verbatim.
    check_validate_error("[LIMP.2.3.3] an import before the `use`",
        "import ha\n\nuse default\n\nschema Trig scope logical:\n" ++
        "    v: Int key\n",
        dv_import_before_use, !T, !IO),

    check_validated("[LIMP.2.3.1] imports under the `use` are fine",
        "use default\nimport ha\nfrom ha import DoorOpen\n" ++
        "schema S:\n    a: Int\n", !T, !IO),

    check_validated("an import with no `use` at all is fine",
        "import ha\nschema S:\n    a: Int\n", !T, !IO),

    % One import can fail both checks, and both are reported ([LERR.1.1.11]).
    check_validate_error("both placement rules can fire on one import (a)",
        "schema S:\n    a: Int\nimport ha\nuse default\n",
        dv_import_after_decl, !T, !IO),

    check_validate_error("both placement rules can fire on one import (b)",
        "schema S:\n    a: Int\nimport ha\nuse default\n",
        dv_import_before_use, !T, !IO),

    % [LIMP.2.3.2] means any non-import top-level declaration, `test`
    % included.
    check_validate_error("[LIMP.2.3.2] a test declaration still counts",
        "test \"t\":\n    produces:\n        activated r\nimport ha\n",
        dv_import_after_decl, !T, !IO),

    % ── identity markers -- [LGRA.5.10], [LFAC.1.7.4], [LFAC.1.7.6] ─────────

    check_validated("[LFAC.1.7.4] a fully marked logical schema is fine",
        "schema S scope logical:\n    a: Int key\n    b: Int mutable\n",
        !T, !IO),

    check_validate_error("[LFAC.1.7.4] an unmarked logical slot is refused",
        "schema S scope logical:\n    a: Int key\n    b: Int\n",
        dv_identity_role_required, !T, !IO),

    check_validate_error("[LFAC.1.7.6] a marker on a `ttl` schema is refused",
        "schema S scope ttl 30_min:\n    a: Int key\n",
        dv_identity_role_non_logical, !T, !IO),

    % [LGRA.5.10], [LFAC.1.7.7]: `ambient` is transparent to the marker rules.
    check_validated("[LGRA.5.10] `logical ambient` still requires markers",
        "schema S scope logical ambient:\n    a: Int key\n", !T, !IO),

    check_validate_error("[LGRA.5.10] and still refuses an unmarked slot",
        "schema S scope logical ambient:\n    a: Int key\n    b: Int\n",
        dv_identity_role_required, !T, !IO),

    % `retained` is no identity role, so a non-logical schema may carry it.
    check_validated("[LGRA.5.1] `retained` on a `ttl` schema is fine",
        "schema S scope ttl 30_min:\n    a: Float retained\n", !T, !IO),

    % ── tolerance -- [LGRA.5.9] ─────────────────────────────────────────────

    check_validated("[LGRA.5.9.1] a tolerance on a mutable Float slot is fine",
        "schema S scope logical:\n    a: Int key\n    b: Float mutable "
            ++ "tolerance 0.5\n", !T, !IO),

    check_validate_error("[LGRA.5.9.10] a tolerance on a `key` slot",
        "schema S scope logical:\n    a: Float key tolerance 0.5\n",
        dv_tolerance_on_key, !T, !IO),

    check_validate_error("[LGRA.5.9.5] a tolerance on a `ttl` schema",
        "schema S scope ttl 30_min:\n    a: Float tolerance 0.5\n",
        dv_tolerance_ttl_schema, !T, !IO),

    check_validate_error("[LGRA.5.9.5] and on any other non-logical base",
        "schema S:\n    a: Float tolerance 0.5\n",
        dv_tolerance_non_logical, !T, !IO),

    check_validate_error("[LGRA.5.9.4] a tolerance on a String slot",
        "schema S scope logical:\n    a: String mutable tolerance 0.5\n",
        dv_tolerance_bad_type, !T, !IO),

    check_validate_error("[LGRA.5.9.6] a float literal on an Int slot",
        "schema S scope logical:\n    a: Int mutable tolerance 0.5\n",
        dv_tolerance_literal_type, !T, !IO),

    % [LGRA.5.9.8]: `tolerance 0` is legal, an Int literal on a Float slot.
    check_validated("[LGRA.5.9.8] `tolerance 0` is legal on a Float slot",
        "schema S scope logical:\n    a: Float mutable tolerance 0\n",
        !T, !IO),

    % [LGRA.5.9.4]: a slot typed by a base or
    % tier-1 unit takes a tolerance, which [LUNI.7.4] converts to the base
    % unit by scale; a tier-2 unit, with no scale, and a dimension name, with
    % no unit to read the literal in, refuse one.
    check_validated("[LGRA.5.9.4] a unit-typed slot takes a tolerance",
        "unit dimension warmth storage float64 base therm\n" ++
        "unit therm: warmth\n" ++
        "schema S scope logical:\n    t: therm mutable tolerance 0.5\n",
        !T, !IO),
    check_validated("[LGRA.5.9.4] and so does a tier-1 one",
        "unit dimension warmth storage float64 base therm\n" ++
        "unit therm: warmth\n" ++
        "unit dbl: warmth = 2 * x\n" ++
        "schema S scope logical:\n    t: dbl mutable tolerance 1\n",
        !T, !IO),
    check_validate_error("[LGRA.5.9.4] a tolerance on a tier-2 unit slot",
        "from math import log10\n" ++
        "unit dimension acidity storage float64 base molar_h\n" ++
        "unit molar_h: acidity\n" ++
        "unit pH: acidity:\n" ++
        "    to_base:   10.0 ** (-x)\n" ++
        "    from_base: -log10(x)\n" ++
        "schema S scope logical:\n    t: pH mutable tolerance 1\n",
        dv_tolerance_bad_type, !T, !IO),
    check_validate_error("[LGRA.5.9.4] a tolerance on a dimension-typed slot",
        "unit dimension warmth storage float64 base therm\n" ++
        "unit therm: warmth\n" ++
        "schema S scope logical:\n    t: warmth mutable tolerance 1\n",
        dv_tolerance_bad_type, !T, !IO),

    % ── action arguments -- [LGRA.10.3.2], [LEXP.7.3b] ──────────────────────

    % `Out`'s slots are nullable so that each case can give a subset of them;
    % [LGRA.13.11] refuses an omitted non-nullable slot, tested below.
    Emit = ( func(Kwargs) =
        "schema In:\n    a: Int\n    f: Float\n" ++
        "schema Out:\n    n: Int?\n    x: Float?\n    s: String?\n" ++
        "rule r:\n    In i\n->\n    emit Out " ++ Kwargs ++ "\n" ),

    check_validated("[LGRA.10.3.2] matching kwargs are fine",
        Emit("n: i.a x: i.f"), !T, !IO),

    % [LGRA.13.11]: every non-nullable slot but `ts` is given, or the action
    % is refused naming the slot; a nullable one takes `null`.
    Full = ( func(Kwargs) =
        "schema In:\n    a: Int\n" ++
        "schema Out:\n    n: Int\n    m: Int\n    note: String?\n"
            ++ "    ts: Time\n" ++
        "rule r:\n    In i\n->\n    emit Out " ++ Kwargs ++ "\n" ),
    check_validated("[LGRA.13.11] every non-nullable slot given; `ts` and "
            ++ "a nullable slot omitted",
        Full("n: i.a m: 1"), !T, !IO),
    check_validate_error("[LGRA.13.11] a non-nullable slot omitted",
        Full("n: i.a"), dv_missing_slot, !T, !IO),

    % [LGRA.10.3.2]: "a kwarg name must be a slot of the schema this action
    % names".
    check_validate_error("[LGRA.10.3.2] a kwarg naming no slot",
        Emit("wibble: 1"), dv_bad_kwarg, !T, !IO),

    % [LFAC.9.3]: `ts` is the engine's to fill. `LFAC.9.3_emit_writes_ts` pins
    % `emit`; these pin `publish`, and that a `ts:` on a schema with no `ts`
    % slot is an unknown slot.
    check_validate_error("[LFAC.9.3] `publish` may not write `ts`",
        "schema In scope ttl 1_h:\n    a: Int\n"
            ++ "schema Out scope ttl 1_h:\n    n: Int\n    ts: Time\n"
            ++ "rule r:\n    In i\n->\n    publish Out n: i.a ts: now()\n",
        dv_ts_read_only, !T, !IO),

    check_validate_error("[LFAC.9.3] but a `ts:` on a schema without one "
            ++ "names no slot",
        Emit("n: i.a ts: now()"), dv_bad_kwarg, !T, !IO),

    % [LEXP.7.3b]: both directions are errors at a slot.
    check_validate_error("[LEXP.7.3b] a Float value into an Int slot",
        Emit("n: i.f"), dv_type_mismatch, !T, !IO),

    check_validate_error("[LEXP.7.3b] and an Int value into a Float slot",
        Emit("x: i.a"), dv_type_mismatch, !T, !IO),

    % A cast's static type is its target.
    check_validated("[LCST.4.1] an explicit cast is the escape hatch",
        Emit("x: i.a::Float"), !T, !IO),

    % A value typed `ty_unknown` fires no slot check.
    check_validated("an untypable value fires no slot check",
        Emit("n: abs(i.a)"), !T, !IO),

    % [LDTL.4.1]: `retain:` is a per-emit TTL override, not a slot, on a
    % `ttl` target.
    check_validated("[LDTL.4.1] `retain:` on `emit` is not a slot",
        "use default:\n    dynamic_ttl: true\n\nschema In:\n    a: Int\n"
            ++ "schema Out scope ttl 1_h:\n    n: Int\n"
            ++ "rule r:\n    In i\n->\n    emit Out n: i.a retain: 30_min\n",
        !T, !IO),

    % ── [LUNI.8.4]: refused wherever it stands, an annotation included ─────
    %
    Dims ="unit dimension span storage float64 base stride\n"
        ++ "unit stride: span\n"
        ++ "unit dimension area storage float64 base stride_squared\n"
        ++ "unit stride_squared: area\n"
        ++ "schema Range scope logical:\n    dist: stride key\n"
        ++ "    w: stride mutable\n",

    check_validate_error("[LUNI.8.4] a dimensioned product in a `where`",
        Dims ++ "rule bad:\n    Range r where (r.dist * r.w) > 100.0\n->\n"
            ++ "    log info \"x\"\n", dv_dim_ambiguous, !T, !IO),

    check_validate_error("[LUNI.8.4] the same product under a typed `let`",
        Dims ++ "rule bad3:\n    Range r\n->\n"
            ++ "    let area: stride_squared = r.dist * r.w\n"
            ++ "    log info \"x\"\n", dv_dim_ambiguous, !T, !IO),

    check_validate_error("[LUNI.8.4] and under an unannotated one",
        Dims ++ "rule bad2:\n    Range r\n->\n"
            ++ "    let other = r.dist * r.w\n"
            ++ "    log info \"x\"\n", dv_dim_ambiguous, !T, !IO),

    check_validated("[LUNI.8.4] the strip and the assert compile",
        Dims ++ "rule ok:\n    Range r\n->\n"
            ++ "    let area = (r.dist::Float * r.w::Float)::stride_squared\n"
            ++ "    log info \"x\"\n", !T, !IO),

    % ── the `call` contract -- [LCRS.8.1], [LADP.8.2.3] ────────────────────

    Call = ( func(Body) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "service ext.api:\n    kwarg body: Int\n    no response\n"
            ++ "rule r:\n    Trig\n->\n" ++ Body ),

    check_validated("[LCRS.8.1] `nocooldown` satisfies the rate contract",
        Call("    call ext.api nocooldown\n"), !T, !IO),

    check_validated("[LCRS.8.1] and so does `cooldown:`",
        Call("    call ext.api cooldown: 5_min\n"), !T, !IO),

    check_validate_error("[LCRS.8.1] but stating neither is refused",
        Call("    call ext.api\n"), dv_call_rate_mod, !T, !IO),

    % [LCRS.8.1]: the modifier may be in the indented block.
    check_validated("[LCRS.8.1] the modifier may be in the block",
        Call("    call ext.api\n        body: 1\n        cooldown: 23_h\n"),
        !T, !IO),

    % ── rate modifiers -- [LGRA.6.6.7] ─────────────────────────────────────

    Header = ( func(Mods) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "rule r" ++ Mods ++ ":\n    Trig\n->\n    log info \"m\"\n" ),

    % The grammar accepts `rate_mod*` and the count is a semantic check.
    check_validated("[LGRA.6.6.1] one `cooldown`",
        Header(" cooldown 5_min"), !T, !IO),

    % `debounce` is not reserved ([LLEX.9.6]), so it may name a constant a
    % `cooldown` reads.
    check_validated("[LLEX.9.6] a `cooldown` may read a constant named `debounce`",
        "const debounce = 2_s\n" ++ Header(" cooldown debounce"), !T, !IO),

    % A front-namespace code from `validate`; see `check_front_error`.
    check_front_error("[LGRA.6.6.7] but not two cooldowns",
        Header(" cooldown 5_min cooldown 1_min"),
        parse_dup_rate_mod, !T, !IO),

    check_front_error("[LGRA.6.6.7] nor two `by:`s",
        Header(" cooldown 5_min by: none by: none"),
        parse_dup_rate_mod, !T, !IO),

    % ── the activation key -- [LCDB.3.3.4] ─────────────────────────────────

    % The log reads the binding, which an unreferenced binding would refuse.
    Keyed = ( func(Mods, Pattern) =
        "schema Ev scope ttl 1_h:\n    who: String\n    ts: Time\n\n"
            ++ "schema S scope logical:\n    who: String key\n    v: Int mutable\n"
            ++ "\nrule r" ++ Mods ++ ":\n    " ++ Pattern ++ " x"
            ++ "\n->\n    log info \"{x.who}\"\n" ),

    check_validate_error("[LCDB.3.3.4] a rate-limited `ttl` binding needs `by:`",
        Keyed(" cooldown 5_min", "Ev"), dv_rate_key_required, !T, !IO),

    check_validated("[LCDB.3.3.4] it is legal with one",
        Keyed(" cooldown 5_min by: x.who", "Ev"), !T, !IO),

    check_validated("[LCDB.3.3.4] or with `by: none`",
        Keyed(" by: none cooldown 5_min", "Ev"), !T, !IO),

    check_validated("[LCDB.3.3.4] a `logical`-only rule may omit it",
        Keyed(" cooldown 5_min", "S"), !T, !IO),

    check_validated("[LCDB.3.3.4] and an unrate-limited one needs none",
        Keyed("", "Ev"), !T, !IO),

    check_validate_error("[LCDB.3.3.4] a slot the schema lacks",
        Keyed(" cooldown 5_min by: x.zone", "Ev"), dv_rate_key_bad_path,
        !T, !IO),

    check_validate_error("[LCDB.3.3.4] a binding the rule lacks",
        Keyed(" cooldown 5_min by: y.who", "Ev"), dv_rate_key_bad_path,
        !T, !IO),

    % A `no` pattern binds no fact, so it can neither need a key nor be one.
    check_validate_error("[LCDB.3.3.4] a negated pattern is not a key",
        "schema Ev scope ttl 1_h:\n    who: String\n\n"
            ++ "schema S scope logical:\n    k: String key\n\n"
            ++ "rule r cooldown 5_min by: e.who:\n    S s\n    no Ev\n"
            ++ "->\n    log info \"{s.k}\"\n",
        dv_rate_key_bad_path, !T, !IO),

    check_validated("[LCDB.3.3.4] a negated `ttl` pattern needs no key",
        "schema Ev scope ttl 1_h:\n    who: String\n\n"
            ++ "schema S scope logical:\n    k: String key\n\n"
            ++ "rule r cooldown 5_min:\n    S s\n    no Ev\n"
            ++ "->\n    log info \"{s.k}\"\n",
        !T, !IO),

    % An `explicit` schema has no identity markers either.
    check_validate_error("[LCDB.3.3.4] the default lifecycle needs `by:` too",
        "schema Ev:\n    who: String\n\n"
            ++ "rule r cooldown 5_min:\n    Ev x\n->\n    log info \"{x.who}\"\n",
        dv_rate_key_required, !T, !IO),

    % ── the fixed-inventory verbs -- [LGRA.10.3.3] ─────────────────────────

    Act = ( func(Body) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "rule r:\n    Trig\n->\n" ++ Body ),

    check_validated("[LGRA.10.3.3] `cache` takes key / value / ttl",
        Act("    cache key: \"k\" value: 1 ttl: 5_min\n"), !T, !IO),

    check_validate_error("[LGRA.10.3.3] `value:` is required",
        Act("    cache key: \"k\"\n"), dv_missing_kwarg, !T, !IO),

    check_validate_error("[LGRA.10.3.3] and the inventory is closed",
        Act("    cache key: \"k\" value: 1 namespace: \"n\"\n"),
        dv_bad_kwarg, !T, !IO),

    check_validated("[LGRA.10.3.3] `cache_delete` needs only `key:`",
        Act("    cache_delete key: \"k\"\n"), !T, !IO),

    % An empty inventory is a contract: `log` takes no kwargs.
    check_validated("[LGRA.10.3.3] `log` takes a level and a message",
        Act("    log info \"m\"\n"), !T, !IO),

    check_validate_error("[LGRA.10.3.3] and no kwargs at all",
        Act("    log info \"m\" category: \"c\"\n"), dv_bad_kwarg, !T, !IO),

    % ── the opaque seals -- [LOPQ.3] and [LOPQ.4] ──────────────────────────

    Sealed = ( func(Guard) =
        "opaque type Key over Bytes\n"
            ++ "schema A scope logical:\n    k1: Key key\n"
            ++ "    k2: Key mutable\n    b: Bytes mutable\n    n: Int mutable\n"
            ++ "rule r:\n    A a where " ++ Guard
            ++ "\n->\n    log info \"m\"\n" ),

    % [LOPQ.3.1]: equality is available on an opaque value.
    check_validated("[LOPQ.3.1] equality on an opaque value is available",
        Sealed("a.k1 == a.k2"), !T, !IO),

    check_validate_error("[LOPQ.3.3] but ordering is sealed",
        Sealed("a.k1 < a.k2"), dv_opaque_no_op, !T, !IO),

    check_validate_error("[LOPQ.3.3] and a representation method is",
        Sealed("a.k1.len() > 0"), dv_opaque_no_op, !T, !IO),

    check_validate_error("[LOPQ.4.1] construction is the forge-prevention seal",
        Sealed("a.k1 == Key(a.b)"), dv_opaque_no_op, !T, !IO),

    check_validate_error("[LOPQ.4.3] and elimination by cast",
        Sealed("a.n == a.k1::Int"), dv_opaque_no_op, !T, !IO),

    % An interpolation body is a path scanned out of a string literal, not an
    % expression node.
    check_validate_error("[LOPQ.3.3] and interpolation of the raw value",
        "opaque type Key over Bytes\n"
            ++ "schema A scope logical:\n    k: Key key\n"
            ++ "rule r:\n    A a\n->\n    log info \"key={a.k}\"\n",
        dv_opaque_no_op, !T, !IO),

    % ── the `call` kwarg contract -- [LGRA.10.3.3] ─────────────────────────

    Contract = ( func(Body) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "service ext.api:\n    kwarg body: Int required\n"
            ++ "    kwarg note: String\n    no response\n"
            ++ "rule r:\n    Trig\n->\n" ++ Body ),

    check_validated("[LGRA.10.3.3] the declared kwargs are admitted",
        Contract("    call ext.api body: 1 note: \"x\" nocooldown\n"),
        !T, !IO),

    check_validate_error("[LGRA.13.9] a required kwarg must be present",
        Contract("    call ext.api note: \"x\" nocooldown\n"),
        dv_missing_kwarg, !T, !IO),

    check_validate_error("[LGRA.10.3.3] an undeclared kwarg is refused",
        Contract("    call ext.api body: 1 wibble: 2 nocooldown\n"),
        dv_bad_kwarg, !T, !IO),

    % `cooldown:` is language-defined, reserved ([LLEX.9.5]), not a service
    % kwarg.
    check_validated("[LGRA.10.3.3] `cooldown:` is language-defined",
        Contract("    call ext.api body: 1 cooldown: 5_min\n"), !T, !IO),

    % [LGRA.10.3.5]: a kwarg is named at most once per action, from either
    % namespace, and on every verb.
    check_validate_error("[LGRA.10.3.5] a service kwarg named twice",
        Contract("    call ext.api body: 1 body: 2 nocooldown\n"),
        dv_duplicate_kwarg, !T, !IO),
    check_validate_error("[LGRA.10.3.5] `cooldown:` named twice",
        Contract("    call ext.api body: 1 cooldown: 5_min cooldown: 1_h\n"),
        dv_duplicate_kwarg, !T, !IO),
    check_validate_error("[LGRA.10.3.5] a slot named twice on `emit`",
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "schema Out:\n    n: Int\n"
            ++ "rule r:\n    Trig t\n->\n    emit Out n: 1 n: 2\n",
        dv_duplicate_kwarg, !T, !IO),
    check_validated("[LGRA.10.3.5] two distinct kwargs in either order",
        Contract("    call ext.api note: \"x\" body: 1 nocooldown\n"),
        !T, !IO),

    % [LCRS.6.3.3]: `retain:` off a hydration endpoint has its own code.
    check_validate_error("[LCRS.6.3.3] `retain:` off a hydration endpoint",
        Contract("    call ext.api body: 1 retain: 5_min nocooldown\n"),
        dv_retain_unwired, !T, !IO),

    % [LADP.8.6.1]: a kwarg declared with a schema, or the kind `Schema`,
    % takes a pattern binding of a fact, and nothing else.
    FactCall = ( func(Type, Arg) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "schema Other scope logical:\n    w: Int key\n"
            ++ "service ext.put:\n    kwarg f: " ++ Type ++ "\n    no response\n"
            ++ "rule r:\n    Trig t\n->\n"
            ++ "    call ext.put f: " ++ Arg ++ " nocooldown\n" ),
    check_validated("[LADP.8.6.1] a schema kwarg takes a binding of it",
        FactCall("Trig", "t"), !T, !IO),
    check_validated("[LADP.8.6.1] a `Schema` kwarg takes any binding",
        FactCall("Schema", "t"), !T, !IO),
    check_validate_error("[LADP.8.6.1] a binding of another schema",
        FactCall("Other", "t"), dv_fact_kwarg_not_binding, !T, !IO),
    check_validate_error("[LADP.8.6.1] a slot value is not a binding",
        FactCall("Schema", "t.v"), dv_fact_kwarg_not_binding, !T, !IO),

    % [LCRS.17.2]: on a `no response` service, `on` and (R23) `timeout` are
    % refused; `error` stays.
    NoResp = ( func(Cont) =
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "service ext.put:\n    kwarg id: Int\n    no response\n"
            ++ "rule r:\n    Trig t\n->\n"
            ++ "    call ext.put id: t.v nocooldown as \"p\"\n" ++ Cont ),
    check_validate_error("[LCRS.17.2] `on` on a `no response` call",
        NoResp("        on response.ok:\n            log info \"x\"\n"),
        dv_no_response_continuation, !T, !IO),
    check_validate_error("[LCRS.17.2] `timeout` on a `no response` call",
        NoResp("        timeout 30_s:\n            log info \"x\"\n"),
        dv_no_response_timeout, !T, !IO),
    check_validated("[LCRS.17.2] `error` on a `no response` call",
        NoResp("        error:\n            log info \"x\"\n"), !T, !IO),

    check_validate_error("[LADP.8.2.3] an undeclared service is named",
        Call("    call totally.unknown nocooldown\n"),
        dv_unknown_service, !T, !IO),

    check_validated("[LIMP.7.3] a locally-declared service resolves",
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "service light.turn_on:\n    kwarg entity_id: String\n"
            ++ "    no response\n"
            ++ "service light.turn_off:\n    kwarg entity_id: String\n"
            ++ "    no response\n"
            ++ "rule r:\n    Trig\n->\n"
            ++ "    call light.turn_on nocooldown\n"
            ++ "    call light.turn_off nocooldown\n", !T, !IO),

    % ── the value-introducer colon -- [LGRA.4.1] ───────────────────────────

    check_validate_error("[LGRA.4.1] `const N: <value>` is refused",
        "const LIMIT: 42\nschema Trig scope logical:\n    v: Int key\n",
        dv_const_colon_literal_retired, !T, !IO),

    % `const N: Int = 1` is the annotated form, told apart by its `=`.
    check_validated("[LGRA.4.1] but `const N: <type> = <value>` is current",
        "const LIMIT: Int = 42\nschema Trig scope logical:\n    v: Int key\n",
        !T, !IO),

    check_validated("[LGRA.4.1] and so is the bare `=` form",
        "const LIMIT = 42\nschema Trig scope logical:\n    v: Int key\n",
        !T, !IO),

    % ── import cycles -- [LIMP.9.11] ───────────────────────────────────────
    %
    % The cycle path ([LIMP.9.11]), which `test_conformance` does not compare.

    check_cycle_path("[LIMP.6.1a] a self-import is a length-1 cycle",
        ["a" - "import a\n"], "a -> a", !T, !IO),

    check_cycle_path("[LIMP.9.11] and a two-step cycle names both",
        ["a" - "import b\n", "b" - "import a\n"], "a -> b -> a", !T, !IO),

    % The path starts at the repeat, not at the entry point.
    check_cycle_path("[LIMP.9.11] and the path is the cycle, not the route",
        ["a" - "import b\n", "b" - "import c\n", "c" - "import b\n"],
        "b -> c -> b", !T, !IO),

    % ── reserved words are not names -- [LLEX.9.5] ────────────────────────

    check_validate_error("[LLEX.9.5] a reserved word as a rule name",
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "rule where:\n    Trig t\n->\n    log info \"m\"\n",
        dv_hard_keyword_name, !T, !IO),

    check_validate_error("[LLEX.9.5] `and` as a pattern binding",
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "rule r:\n    Trig and\n->\n    log info \"m\"\n",
        dv_hard_keyword_name, !T, !IO),

    % [LLEX.9.6] is generated from the grammar, which has no `match`.
    check_validated("[LLEX.9.6] a word with no production is a name",
        "schema Trig scope logical:\n    v: Int key\n"
            ++ "rule r:\n    Trig match where match.v > 0\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    check_validate_error("[LLEX.9.5] a slot may not be named `schema`",
        "schema S scope logical:\n    k: String key\n"
            ++ "    schema: String mutable\n",
        dv_hard_keyword_name, !T, !IO),

    % A marker word is reserved, though it parses as a slot name.
    check_validate_error("[LLEX.9.5] a slot may not be named `key`",
        "schema S scope logical:\n    key: String key\n",
        dv_hard_keyword_name, !T, !IO),

    check_validate_error("[LLEX.9.5] a slot may not be named `over`",
        "schema S scope logical:\n    k: String key\n"
            ++ "    over: Int mutable\n",
        dv_hard_keyword_name, !T, !IO),

    % [LNAM.2.1.1]: reservation is case-sensitive. The kind `Schema` is
    % reserved as `type` on [LLEX.9.6]; at a slot that is [LLEX.9.7]'s last
    % row.
    check_validate_error("[LLEX.9.6] the kind `Schema` is reserved at a slot",
        "schema S scope logical:\n    k: String key\n"
            ++ "    Schema: String mutable\n",
        dv_hard_keyword_name, !T, !IO),
    check_validated("[LLEX.9.5] `Where` is not `where`",
        "schema S scope logical:\n    k: String key\n"
            ++ "    Where: String mutable\n", !T, !IO),

    % [LSER.6.6.1] is unconditional -- there is no series in this file.
    check_validate_error("[LSER.6.6.1] an aggregation name as a slot",
        "schema S scope logical:\n    k: String key\n"
            ++ "    mean: Float mutable\n",
        dv_companion_slot_collision, !T, !IO),

    % The percentile family has no [LLEX.9.6] row; [LLEX.9.5] states it.
    check_validate_error("[LLEX.9.5] the percentile family, rowless",
        "schema S scope logical:\n    k: String key\n"
            ++ "    p95: Float mutable\n",
        dv_companion_slot_collision, !T, !IO),

    check_validate_error("[LLEX.9.5] a builtin function name as a constant",
        "const abs = 5\n", dv_reserved_builtin_name, !T, !IO),

    check_validate_error("[LLEX.9.5] a control-plane modifier as a slot",
        "schema S scope logical:\n    k: String key\n"
            ++ "    cooldown: Int mutable\n",
        dv_reserved_meta_kwarg, !T, !IO),

    % A `let` name is a binding.
    check_validate_error("[LLEX.9.5] a reserved word as a `let` name",
        "schema S scope logical:\n    k: String key\n"
            ++ "rule r:\n    S s\n->\n    let gap = s.k\n    log info \"m\"\n",
        dv_hard_keyword_name, !T, !IO),

    % ── what a rule's names are used for -- [LGRA.8.6], [LEXP.9.6.1] ─────────

    check_validate_error("[LGRA.8.6] a written binding nothing references",
        "schema G scope logical:\n    root: String key\n"
            ++ "rule r:\n    G g\n->\n    log info \"m\"\n",
        dv_unreferenced_binding, !T, !IO),

    check_validated("[LGRA.8.6] a reference in the pattern's own `where`",
        "schema G scope logical:\n    root: String key\n"
            ++ "rule r:\n    G g where g.root == \"/src\"\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    check_validated("[LGRA.8.6] a reference inside an interpolation",
        "schema G scope logical:\n    root: String key\n"
            ++ "rule r:\n    G g\n->\n    log info \"{g.root}\"\n", !T, !IO),

    check_validated("[LGRA.8.6] an unbound pattern owes nothing",
        "schema G scope logical:\n    root: String key\n"
            ++ "rule r:\n    G\n->\n    log info \"m\"\n", !T, !IO),

    check_validate_error("[LEXP.9.6.1] `cached()` on two positive patterns",
        "schema Z scope logical:\n    name: String key\n"
            ++ "schema R scope logical:\n    id: String key\n"
            ++ "    zone: String mutable\n"
            ++ "rule r:\n    Z z\n"
            ++ "    R x where x.zone == z.name and cached(\"k\") == x.id\n"
            ++ "->\n    log info \"m\"\n",
        dv_nonfact_where_multipattern, !T, !IO),

    check_validate_error("[LTIM.2.6.2] `now()` on two positive patterns",
        "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and (now() - e.fired) > 1_h\n"
            ++ "->\n    log info \"m\"\n",
        dv_now_multipattern_unsupported, !T, !IO),

    % [LTIM.2.4.1]'s other reads: `monotonic_ns()`
    % is a clock read and a zone other than `"UTC"` a zone read, so each is
    % [LTIM.2.6.2]'s refusal on two positive patterns. A series read is the
    % vector `LTIM.2.6.2_series_read_multipattern_rejects`.
    check_validate_error("[LTIM.2.6.2] `monotonic_ns()` on two positive patterns",
        "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and monotonic_ns() > 1_s\n"
            ++ "->\n    log info \"m\"\n",
        dv_now_multipattern_unsupported, !T, !IO),

    check_validate_error("[LTIM.2.6.2] a zone read on two positive patterns",
        "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and "
            ++ "e.fired.local(\"Europe/Paris\").hour > 8\n"
            ++ "->\n    log info \"m\"\n",
        dv_now_multipattern_unsupported, !T, !IO),

    % `"UTC"` resolves no zone ([LTIM.2.4.1]: "any zone but `UTC`").
    check_validated("[LTIM.2.4.1] a `\"UTC\"` zone is not a zone read",
        "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and e.fired.local(\"UTC\").hour > 8\n"
            ++ "->\n    log info \"m\"\n", !T, !IO),

    % Nor is a `const` whose folded value is `"UTC"` ([LTIM.2.6.2]: "a
    % literal, or a `const` whose folded value it is"). A `const` naming
    % another zone still counts.
    check_validated("[LTIM.2.6.2] a `const` \"UTC\" zone is not a zone read",
        "const HOME = \"UTC\"\n"
            ++ "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and e.fired.local(HOME).hour > 8\n"
            ++ "->\n    log info \"m\"\n", !T, !IO),
    check_validate_error("[LTIM.2.6.2] a `const` naming another zone is one",
        "const HOME = \"Europe/Paris\"\n"
            ++ "schema A scope logical:\n    k: Int key\n"
            ++ "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    A a\n"
            ++ "    E e where e.k == a.k and e.fired.local(HOME).hour > 8\n"
            ++ "->\n    log info \"m\"\n",
        dv_now_multipattern_unsupported, !T, !IO),

    check_validated("[LTIM.2.6.1] one positive pattern re-evaluates on ticks",
        "schema E scope logical:\n    k: Int key\n    fired: Time mutable\n"
            ++ "rule r:\n    E e where (now() - e.fired) > 1_h\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    check_validated("[LEXP.9.6.1] one positive pattern keeps the read",
        "schema R scope logical:\n    id: String key\n"
            ++ "rule r:\n    R x where cached(\"k\") == x.id\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    % [LUNI.9.2]: "Over a slot with no unit there
    % is no dimension to state, and the `let` needs none." The unit-carrying
    % cases are the `compiler/LUNI.9.2_*` vectors.
    check_validated("[LUNI.9.2] an unannotated `let` over `integral` of a "
            ++ "unitless slot needs no annotation",
        "schema Flow scope logical:\n    entity_id: String key\n"
            ++ "    q: Float mutable\n"
            ++ "series Flow.q:\n    integral sliding 5_min gap zero\n"
            ++ "rule r:\n    Flow f\n->\n    let x = integral(f)\n"
            ++ "    log info \"{x}\"\n", !T, !IO),

    % ── series identity -- [LSER.7.6.1] ────────────────────────────────────

    check_validated("[LSER.7.6.1] a `logical` key is the identity",
        "schema R scope logical:\n    device: String key\n"
            ++ "    v: Float mutable\n"
            ++ "series R.v:\n    mean all_time\n", !T, !IO),

    check_validate_error("[LSER.7.6.1] a keyless `logical` schema has none",
        "schema R scope logical:\n    v: Float mutable\n"
            ++ "series R.v:\n    mean all_time\n",
        dv_series_no_identity_slot, !T, !IO),

    check_validated("[LSER.7.6.2] and `by: none` asks for one global series",
        "schema R scope logical:\n    v: Float mutable\n"
            ++ "series R.v (by: none):\n    mean all_time\n", !T, !IO),

    check_validate_error("[LSER.7.6.1] `by:` must name a declared slot",
        "schema R scope logical:\n    device: String key\n"
            ++ "    v: Float mutable\n"
            ++ "series R.v (by: bogus):\n    mean all_time\n",
        dv_series_bad_identity_slot, !T, !IO),

    % ── [LEXP.7.3a]: `**` at any exponent is admitted ──────────────────────
    %
    % An integer exponent of either sign is exact: [LEXP.7.3a] admits
    % `2 ** -3 == 0.125` by the correctly-rounded `pow`.
    check_validated("[LEXP.7.3a] a negative integer exponent is exact",
        "schema S scope logical:\n    k: Int key\n    v: Float mutable\n"
            ++ "rule r:\n    S s where s.v ** -3 > 0.0\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    check_validated("[LEXP.7.3a] as is an `Int` slot of unknown sign",
        "schema S scope logical:\n    k: Int key\n    n: Int mutable\n"
            ++ "rule r:\n    S s where 2 ** s.n > 0\n->\n"
            ++ "    log info \"m\"\n", !T, !IO),

    % ── slot-name uniqueness -- [LGRA.13.4] ────────────────────────────────

    % The name alone is the key; these differ in type and marker.
    check_validate_error("[LGRA.13.4] a slot name declared twice",
        "schema Trig scope logical:\n    v: Int key\n    v: String mutable\n",
        dv_duplicate_slot, !T, !IO),

    check_validated("[LGRA.13.4] but two schemas may share a slot name",
        "schema A scope logical:\n    v: Int key\n"
            ++ "schema B scope logical:\n    v: Int key\n", !T, !IO),

    % ── [LFAC.9.1] / [LNUL.8.7] / [LNUL.8.10]: `ts`, and what may be null ───

    % A `ttl` schema carries no markers, so these pin the `ts` type alone.
    check_validated("[LFAC.9.1] a `ts: Time` slot",
        "schema Ev scope ttl 1_h:\n    id: Int\n    ts: Time\n", !T, !IO),

    % `ts` is the engine's slot: require-all does not reach it, and a marker
    % on it is DS_VALIDATE_TS_MARKED on any lifecycle, ahead of the generic
    % non-logical marker code.
    check_validated("[LFAC.9.1] an unmarked `ts` on a `logical` schema",
        "schema Ev scope logical:\n    id: Int key\n    ts: Time\n", !T, !IO),

    check_validate_error("[LFAC.9.1] `ts` marked `key`",
        "schema Ev scope logical:\n    id: Int key\n    ts: Time key\n",
        dv_ts_marked, !T, !IO),

    check_validate_error("[LFAC.9.1] `ts` marked `mutable`",
        "schema Ev scope logical:\n    id: Int key\n    ts: Time mutable\n",
        dv_ts_marked, !T, !IO),

    check_validate_error("[LFAC.9.1] a marked `ts` on a `ttl` schema is 1825",
        "schema Ev scope ttl 1_h:\n    id: Int\n    ts: Time key\n",
        dv_ts_marked, !T, !IO),

    check_validate_error("[LFAC.9.1] a `ts` of another type",
        "schema Ev scope ttl 1_h:\n    id: Int\n    ts: Int\n",
        dv_ts_not_time, !T, !IO),

    % Type and nullability are one test: the engine fills `ts`.
    check_validate_error("[LFAC.9.1] a nullable `ts`, even a `Time?`",
        "schema Ev scope ttl 1_h:\n    id: Int\n    ts: Time?\n",
        dv_ts_not_time, !T, !IO),

    check_validate_error("[LFAC.9.1] and a nullable `Int` epoch `ts`",
        "schema Ev scope ttl 1_h:\n    id: Int\n    ts: Int?\n",
        dv_ts_not_time, !T, !IO),

    % [LNUL.8.7] admits `Time?` on any slot but `ts`.
    check_validated("[LNUL.8.7] a `Time?` slot that is not `ts`",
        "schema Ev scope logical:\n    id: Int key\n    seen_at: Time? mutable\n",
        !T, !IO),

    check_validated("[LNUL.8.7] and a `Date?` or `Duration?`",
        "schema Ev scope logical:\n    id: Int key\n    due: Date? mutable\n"
            ++ "    span: Duration? mutable\n", !T, !IO),

    check_validate_error("[LNUL.8.10] a `key` slot may not be nullable",
        "schema Sensor scope logical:\n    k: Float? key\n",
        dv_nullable_key, !T, !IO),

    % `mutable` is a marker but no part of the identity.
    check_validated("[LNUL.8.10] but a `mutable` one may",
        "schema Sensor scope logical:\n    k: Float key\n"
            ++ "    v: Float? mutable\n", !T, !IO),

    % ── [LNUL.5.1]: the typed-`let` concrete-value position ────────────────
    Nullable = ( func(Body) =
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    n: Float? mutable\n"
            ++ "rule r:\n    Sensor s\n->\n" ++ Body
            ++ "    log info \"m\"\n" ),

    check_validate_error("[LNUL.5.1] a `T?` into a typed `let` is refused",
        Nullable("    let x: Float = s.n\n"),
        dv_nullable_unnarrowed, !T, !IO),

    % The annotation says how concrete.
    check_validated("[LNUL.5.1] but a `Float?` annotation admits it",
        Nullable("    let x: Float? = s.n\n"), !T, !IO),

    % "a typed `let` RHS": the bare form carries the `?` to where `x` is used.
    check_validated("[LNUL.5.1] and an unannotated `let` is not the position",
        Nullable("    let x = s.n\n"), !T, !IO),

    % [LNUL.5.4] case (b): `x ?? d` has the default's type, `?` stripped.
    check_validated("[LNUL.5.3] `??` supplies the concrete value",
        Nullable("    let x: Float = s.n ?? 0.0\n"), !T, !IO),

    % ── [LNUL.5.1]: a `call` kwarg and a builtin argument ──────────────────
    %
    % Each refusal has an admitting twin: a guard narrows, `??` supplies, and
    % the absence tests take a `T?`.
    Where = ( func(Test) =
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    n: Float? mutable\n"
            ++ "rule r:\n    Sensor s where " ++ Test
            ++ "\n->\n    log info \"m\"\n" ),
    Calls = ( func(Value) =
        "schema Sensor scope logical:\n    entity_id: String key\n"
            ++ "    n: Float? mutable\n\n"
            ++ "service svc.a:\n    kwarg x: Float\n    no response\n\n"
            ++ "rule r:\n    Sensor s\n->\n"
            ++ "    call svc.a x: " ++ Value ++ " nocooldown\n" ),

    check_validate_error("[LNUL.5.1] a `T?` builtin argument is refused",
        Where("abs(s.n) > 1.0"), dv_nullable_unnarrowed, !T, !IO),
    check_validated("[LNUL.5.1] the same argument narrowed is admitted",
        Where("s.n is not null and abs(s.n) > 1.0"), !T, !IO),
    check_validated("[LNUL.5.1] the same argument defaulted is admitted",
        Where("abs(s.n ?? 0.0) > 1.0"), !T, !IO),
    check_validated("[LNUL.4.4] `x is null` takes a `T?`: it is the test",
        Where("s.n is null"), !T, !IO),
    check_validate_error("[LNUL.5.1] a `T?` `call` kwarg is refused",
        Calls("s.n"), dv_nullable_unnarrowed, !T, !IO),
    check_validated("[LNUL.5.1] a `call` kwarg defaulted is admitted",
        Calls("s.n ?? 0.0"), !T, !IO),

    % [LNUL.5.1] with [LNUL.8.4]: `has()` tests its path and
    % takes it unresolved, but its root is a concrete value. A `Json?` root
    % is refused until a guard narrows it; a `Json` root never is.
    Json = ( func(Body, Test) =
        "schema D scope logical:\n    entity_id: String key\n"
            ++ "    body: " ++ Body ++ " mutable\n"
            ++ "rule r:\n    D d where " ++ Test
            ++ "\n->\n    log info \"x\"\n" ),
    check_validate_error("[LNUL.5.1] `has()` over an unnarrowed `Json?` root "
            ++ "is refused",
        Json("Json?", "has(d.body.x)"), dv_nullable_unnarrowed, !T, !IO),
    check_validate_error("[LNUL.5.1] a deeper path keeps the same root",
        Json("Json?", "has(d.body.x.y)"), dv_nullable_unnarrowed, !T, !IO),
    check_validated("[LNUL.5.1] the root narrowed, `has()` is admitted",
        Json("Json?", "d.body is not null and has(d.body.x)"), !T, !IO),
    check_validated("[LNUL.8.4] over a `Json` root, `has()` is admitted",
        Json("Json", "has(d.body.x)"), !T, !IO),

    % [LGRA.10.1.5]: `record_event` is not an action at all.
    check_validate_error("[LGRA.10.1.5] `record_event` is refused",
        "schema Out:\n    n: Int\nschema In:\n    a: Int\n" ++
        "rule r:\n    In i\n->\n    record_event Out n: 1\n",
        dv_record_event_retired, !T, !IO).

%-----------------------------------------------------------------------------%
% The typing walk
%-----------------------------------------------------------------------------%
%
% Every case runs from source through `resolve`.

    % Type the `where` of the first rule's first pattern, in that rule's scope.
    %
:- pred typed(string::in, lexp_7_type::out) is semidet.

typed(Guard, Type) :-
    % `distance` is imported so a guard can call its members ([LIMP.3.3.4]);
    % `resolve_file` trusts the import and `dsc.libcall` rewrites the call.
    Src = "import distance\n" ++
        "unit dimension warmth storage float64 base therm\n" ++
        "unit celsius: warmth label \"C\" alias degC\n" ++
        "schema S:\n    a: Int\n    n: Float?\n    t: celsius\n" ++
        "    j: Json\n    s: String\n" ++
        "    t1: Time\n    t2: Time\n    d: Duration\n    dt: Date\n" ++
        "rule r:\n    S s where " ++ Guard ++ "\n->\n    log info \"m\"\n",
    built(Src, Ast),
    resolve_file(Ast, resolve_ok(RF)),
    RF ^ rf_scopes = [Scope],
    W = first_where(RF ^ rf_ast),
    Type = type_of_expr(type_env(RF, Scope, set.init), W).

:- pred check_type(string::in, string::in, lexp_7_type::in,
                   tally::in, tally::out, io::di, io::uo) is det.

check_type(Name, Guard, Want, !T, !IO) :-
    ( if typed(Guard, Got), Got = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

    % Asserts the CODE of the first diagnostic, never the wording.
    %
:- pred check_type_error(string::in, string::in, ds_validate::in,
                         tally::in, tally::out, io::di, io::uo) is det.

check_type_error(Name, Guard, Want, !T, !IO) :-
    ( if
        typed(Guard, ty_error(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(Want)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

    % The guard is refused, and no diagnostic carries `NotWant`.
    %
:- pred check_type_error_not(string::in, string::in, ds_validate::in,
                             tally::in, tally::out, io::di, io::uo) is det.

check_type_error_not(Name, Guard, NotWant, !T, !IO) :-
    ( if
        typed(Guard, ty_error(Ds)),
        not (
            list.member(D, Ds),
            D ^ dg_code = dc_validate(NotWant)
        )
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_typecheck(tally::in, tally::out, io::di, io::uo) is det.

test_typecheck(!T, !IO) :-

    Int = ty_known(ds_type(lk_int, dimensionless, non_null)),
    Float = ty_known(ds_type(lk_float, dimensionless, non_null)),
    Bool = ty_known(ds_type(lk_bool, dimensionless, non_null)),
    NullBool = ty_known(ds_type(lk_bool, dimensionless, nullable)),
    Duration = ty_known(ds_type(lk_duration, dim(time_dimension, no), non_null)),

    % ── slot access, which is where a type enters an expression ─────────────

    check_type("a slot access takes the slot's declared type",
        "s.a > 0", Bool, !T, !IO),

    % A `Float?` slot is where a `T?` enters, and the comparison propagates
    % it.
    check_type("[LNUL.4.1] a nullable operand makes the comparison nullable",
        "s.n > 0.0", NullBool, !T, !IO),

    % [LNUL.4.9]: `is` is total, "never null, never raising".
    check_type("[LNUL.4.9] `is` is total even on a nullable operand",
        "s.n is not null", Bool, !T, !IO),

    check_type_error("[LUNI.7.1] an unknown slot is named",
        "s.wibble > 0", dv_unknown_slot, !T, !IO),

    check_type_error("[LGRA.22.7] an unresolved name is refused",
        "wibble > 0", dv_unknown_binding, !T, !IO),

    % ── the cast table ──────────────────────────────────────────────────────

    check_type("[LCST.4.5.2] `Int -> Float` is total and needs no `?`",
        "s.a::Float > 0.0", Bool, !T, !IO),

    % Both halves of [LCST.4.3.2]'s bijection.
    check_type_error("[LCST.4.3.1] a fallible cast without `?` is refused",
        "s.s::Int > 0", dv_cast_nullability, !T, !IO),

    check_type_error("[LCST.4.3.2] a redundant `?` is refused",
        "s.a::Float? > 0.0", dv_cast_nullability, !T, !IO),

    check_type_error("[LCST.4.3.1] a nullable source needs `?`",
        "s.n::Int > 0", dv_cast_nullability, !T, !IO),

    check_type_error("[LCST.4.5.2] a scalar does not convert to `Json`",
        "s.a::Json", dv_cast_undefined, !T, !IO),

    check_type_error("[LCST.4.1.6] a schema is not a cast target",
        "s.a::S", dv_cast_undefined, !T, !IO),

    % [LUNI.8.7.1], [LUNI.8.7.2]: the cast's result carries the target's
    % dimension: the unit's for `::<unit>`, none for `::Float`.
    check_type("[LUNI.8.7.1] `::<unit>` carries the target's dimension",
        "s.a::Float::celsius",
        ty_known(ds_type(lk_float, dim(decl_ref("", "warmth"), yes(decl_ref("", "celsius"))),
            non_null)), !T, !IO),

    check_type("[LUNI.8.7.2] `::Float` strips the dimension",
        "s.t::Float > 0.0", Bool, !T, !IO),

    % A unit alias is a cast target, though [LUNI.7.5] refuses it as a slot
    % type.
    check_type("[LUNI.7.5] an alias is a cast target, resolved to canonical",
        "s.a::Float::degC",
        ty_known(ds_type(lk_float, dim(decl_ref("", "warmth"), yes(decl_ref("", "celsius"))),
            non_null)), !T, !IO),

    % [LCST.4.1.5]: `x::A::B` types `x::A` first, so a nullable link forces a
    % `?` on the next one.
    check_type_error("[LCST.4.1.5] `x::Int?::Float` is a chaining error",
        "s.s::Int?::Float > 0.0", dv_cast_nullability, !T, !IO),

    check_type("[LCST.4.1.5] and `x::Int?::Float?` is not",
        "s.s::Int?::Float? > 0.0", NullBool, !T, !IO),

    % ── `??`, which is [LNUL.5.4]'s case (b) ────────────────────────────────

    % "`x ?? d` (with `d : T`) has type `T`".
    check_type("[LNUL.5.3] `??` yields the default's type, non-null",
        "(s.n ?? 0.0) > 0.0", Bool, !T, !IO),

    % ── the conservative unknown ────────────────────────────────────────────

    % A Json projection is untyped, not an error.
    check_type("[LEXP.6] a Json projection is unknown, not an error",
        "s.j.field", ty_unknown, !T, !IO),

    % ── calls -- [LEXP.5.8.1]'s arities, and the return types a clause gives ─

    % The winner of a two-operand `min` over bare numbers has no static kind
    % ([LUNI.8.8]), so the call is well-formed and untyped.
    check_type("a builtin with no stated return type is unknown, not an error",
        "min(s.a, s.a)", ty_unknown, !T, !IO),

    % The five the clauses do give, plus the distance family.
    check_type("[LTIM.2.1.1] `now()` returns a Time",
        "now()", ty_known(ds_type(lk_time, dimensionless, non_null)),
        !T, !IO),

    check_type("[LTIM.2.2.1] `monotonic_ns()` returns a Duration",
        "monotonic_ns()",
        ty_known(ds_type(lk_duration, dim(time_dimension, no), non_null)), !T, !IO),

    check_type_error("[LTIM.2.2.1] `monotonic()` is an unknown function",
        "monotonic()", dv_unknown_function, !T, !IO),

    check_type("[LGRA.9.8.1] `len(<Json>)` returns an Int",
        "len(s.j)", Int, !T, !IO),

    check_type("[LEXP.5.9.1] a geometric distance returns a Float",
        "distance.euclidean(1.0, 2.0, 3.0, 4.0)", Float, !T, !IO),

    % Neither string distance is a [LEXP.17.2] row. `distance` is an
    % imported library, so [LGRA.22.9] reads the call as its member, never a
    % binding's access, and an unresolved called name is [LGRA.22.7]'s
    % `DS_VALIDATE_UNKNOWN_FUNCTION` ([LIMP.3.3.4]), not an unknown binding.
    check_type_error("[LGRA.22.9] `distance.levenshtein` is unknown",
        "distance.levenshtein(s.s, s.s)", dv_unknown_function, !T, !IO),
    check_type_error_not("[LGRA.22.9] `distance` is not read as a binding",
        "distance.levenshtein(s.s, s.s)", dv_unknown_binding, !T, !IO),
    check_type_error("[LGRA.22.9] `distance.hamming` is unknown",
        "distance.hamming(s.s, s.s)", dv_unknown_function, !T, !IO),
    check_type_error_not("[LGRA.22.9] nor for `distance.hamming`",
        "distance.hamming(s.s, s.s)", dv_unknown_binding, !T, !IO),

    % [LEXP.5.8.1]: only the declared arities are legal. `distance.euclidean`
    % declares 4 (2D) and 6 (3D), so 5 is refused.
    check_type_error("[LEXP.5.8.1] five arguments is neither 2D nor 3D",
        "distance.euclidean(1.0, 2.0, 3.0, 4.0, 5.0)", dv_bad_arity,
        !T, !IO),

    check_type("[LEXP.5.3.1] and six is the 3D form",
        "distance.euclidean(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)", Float, !T, !IO),

    check_type_error("[LTIM.2.1.1] `now(x)` is an arity error",
        "now(s.a)", dv_bad_arity, !T, !IO),

    check_type_error("[LGRA.9.8.11] an unknown function is refused",
        "wibble(s.a)", dv_unknown_function, !T, !IO),

    % An argument's own error outranks the call's.
    check_type_error("an argument's own error wins over the call's",
        "abs(s.wibble)", dv_unknown_slot, !T, !IO),

    % ── unit literals ───────────────────────────────────────────────────────

    check_type("[LUNI.3.1.7] a unit literal takes its symbol's dimension",
        "5_celsius",
        ty_known(ds_type(lk_float, dim(decl_ref("", "warmth"), yes(decl_ref("", "celsius"))),
            non_null)),
        !T, !IO),

    check_type_error("[LUNI.3.1.7] an undeclared unit suffix is named",
        "s.a > 5_wibble", dv_unknown_unit, !T, !IO),

    % `typed/2`'s file declares no time unit: these resolve with no import
    % ([LUNI.4.1.2]).
    check_type("[LUNI.10.2] a time suffix resolves with no unit declared",
        "30_s",
        ty_known(ds_type(lk_duration,
            dim(time_dimension, yes(core_decl("s"))), non_null)), !T, !IO),

    check_type("[LUNI.10.2] and so do the sub-second spellings",
        "500_ms",
        ty_known(ds_type(lk_duration,
            dim(time_dimension, yes(core_decl("ms"))), non_null)),
        !T, !IO),

    % [LTIM.1.3.2]: a `time`-dimensioned literal is a `Duration`, so it
    % compares with `Time - Time` ([LTIM.1.3.3], [LTIM.5.4]).
    check_type("[LTIM.5.4] and compare against a `Time - Time` difference",
        "(s.t1 - s.t2) > 30_s", Bool, !T, !IO),

    % A non-time dimensioned literal keeps its dimension and Float leaf.
    check_type("[LTIM.1.3.2] a non-time dimension is unaffected",
        "5_celsius > 4_celsius", Bool, !T, !IO),

    % ── arithmetic -- [LEXP.7.1a] through [LEXP.7.6] ────────────────────────

    check_type("[LEXP.7.2] all operands Int gives Int",
        "s.a + 1", Int, !T, !IO),

    check_type("[LEXP.7.3] any operand Float gives Float",
        "s.a + 1.5", Float, !T, !IO),

    % [LEXP.7.4]: `/` is always Float; `//` follows the operand rule.
    check_type("[LEXP.7.4] `/` is Float even on two Ints",
        "s.a / 2", Float, !T, !IO),

    check_type("[LEXP.7.5] `//` follows the operand rule and stays Int",
        "s.a // 2", Int, !T, !IO),

    check_type_error("[LEXP.7.1a] there is no string `+`",
        "s.s + s.s == \"xy\"", dv_bad_operand_type, !T, !IO),

    % [LNUL.5.1]: arithmetic is among "the Kleene consumers" and propagates.
    check_type("[LNUL.5.1] arithmetic on a `T?` propagates null",
        "s.n + 1.0", ty_known(ds_type(lk_float, dimensionless, nullable)),
        !T, !IO),

    % The comparison over it is `Bool?`, and does not fire on null
    % ([LNUL.4.3]).
    check_type("[LNUL.5.1] and the comparison over it is `Bool?`",
        "s.n + 1.0 > 0.0", NullBool, !T, !IO),

    % [LNUL.5.4] case (a): the guard makes the tail's `s.n` a `Float`.
    check_type("[LNUL.5.4] an `is not null` guard narrows to its right",
        "s.n is not null and s.n + 1.0 > 0.0", Bool, !T, !IO),

    % [LNUL.5.4]: `or` does not narrow.
    check_type("[LNUL.5.4] `or` does not narrow",
        "s.n is null or s.n + 1.0 > 0.0", NullBool, !T, !IO),

    % [LNUL.5.4]: nor does `not (x is null)`.
    check_type("[LNUL.5.4] nor does `not (x is null)`",
        "not (s.n is null) and s.n + 1.0 > 0.0",
        NullBool, !T, !IO),

    % ── `**` -- [LEXP.7.3a] ─────────────────────────────────────────────────

    check_type("[LEXP.7.3a] `Int ** <non-negative literal>` stays Int",
        "s.a ** 2", Int, !T, !IO),

    % "so `2 ** -3 == 0.125`".
    check_type("[LEXP.7.3a] a negative exponent gives Float",
        "s.a ** -3", Float, !T, !IO),

    check_type("[LEXP.7.3a] an unknown-sign exponent gives Float",
        "s.a ** s.a", Float, !T, !IO),

    % ── the dimensional check ───────────────────────────────────────────────

    check_type("[LUNI.8.3] a bare scalar preserves the dimension",
        "s.t * 2",
        ty_known(ds_type(lk_float, dim(decl_ref("", "warmth"), yes(decl_ref("", "celsius"))),
            non_null)), !T, !IO),

    check_type_error("[LUNI.8.4] dimensioned * dimensioned needs annotating",
        "s.t * s.t", dv_dim_ambiguous, !T, !IO),

    % `**` refuses a dimensioned base even with a bare scalar exponent: `m ** 2`
    % wants `m²`, and DS has no compound unit algebra.
    check_type_error("[LUNI.8.4] `**` refuses a dimensioned base outright",
        "s.t ** 2", dv_dim_ambiguous, !T, !IO),

    % ── bitwise -- [LEXP.7.7], [LEXP.7.8] ───────────────────────────────────

    check_type("[LEXP.7.7] integer operands give Int",
        "s.a & 1", Int, !T, !IO),

    check_type_error("[LEXP.7.7] a Float operand is refused",
        "s.a & 1.5", dv_bitwise_type, !T, !IO),

    % [LEXP.7.7]: an error "when the type is known statically"; a
    % `ty_unknown` operand is not.
    check_type("[LEXP.7.7] and does not fire on an unknown operand",
        "s.j.field & 1", ty_unknown, !T, !IO),

    check_type_error("[LEXP.7.8] a negative literal shift is refused",
        "s.a << -1", dv_negative_shift, !T, !IO),

    % ── temporal arithmetic -- [LTIM.4.1.1], [LTIM.4.2.1] ───────────────────

    check_type("[LTIM.4.1.1] `Time - Time` is a Duration",
        "s.t1 - s.t2",
        ty_known(ds_type(lk_duration, dim(time_dimension, no), non_null)), !T, !IO),

    check_type("[LTIM.4.1.1] `Time + Duration` stays a Time",
        "s.t1 + s.d",
        ty_known(ds_type(lk_time, dimensionless, non_null)), !T, !IO),

    % [LTIM.4.2.2] is about the value, not the suffix: `24_h` is a whole day.
    check_type("[LTIM.4.2.2] a whole day in hours is a legal `Date` addend",
        "(s.dt + 24_h) == s.dt", Bool, !T, !IO),

    check_type_error("[LTIM.4.2.2] but a sub-day one is not",
        "(s.dt + 12_h) == s.dt", dv_date_subday_arithmetic, !T, !IO),

    check_type("[LTIM.4.2.2] and a computed duration is the runtime's",
        "(s.dt + (s.t1 - s.t2)) == s.dt", Bool, !T, !IO),

    check_type("[LTIM.4.2.1] `Date - Date` is a Duration",
        "s.dt - s.dt",
        ty_known(ds_type(lk_duration, dim(time_dimension, no), non_null)), !T,
        !IO),

    % [LTIM.4.1.1] gives `Int * Duration`, `Duration * Int` and `Duration /
    % Int`; `Duration * Duration` is two dimensions ([LUNI.8.4]).
    check_type("[LTIM.4.1.1] `Int * Duration` is a Duration",
        "2 * s.d",
        ty_known(ds_type(lk_duration, dim(time_dimension, no), non_null)), !T,
        !IO),

    check_type_error("[LUNI.8.4] `Duration * Duration` is two dimensions",
        "s.d * s.d", dv_dim_ambiguous, !T, !IO),

    check_type_error("[LTIM.4.1.1] `Time + Time` has no row",
        "s.t1 + s.t2", dv_bad_operand_type, !T, !IO).

%-----------------------------------------------------------------------------%
% Narrowing -- [LNUL.5.4] case (a)
%-----------------------------------------------------------------------------%
%
% Run from source: `x is not null and …` and `not (x is null) and …` differ
% by one word and must produce different trees.

    % The `where` of the first pattern of the first rule.
    %
:- func first_where(ast_file) = lgra_9_3_1_expr.
:- mode first_where(in) = out is semidet.

first_where(ast_file(_, Decls)) = W :-
    first_rule(Decls, R),
    R ^ ar_lhs = [alc_pattern(ap_simple(Body)) | _],
    Body ^ apb_where = yes(W).

    % The first rule, wherever it is among the declarations.
    %
:- pred first_rule(list(ast_decl)::in, ast_rule::out) is semidet.

first_rule([D | Ds], R) :-
    ( if D = ad_rule(Rule) then
        R = Rule
    else
        first_rule(Ds, R)
    ).

:- pred check_narrow(string::in, string::in, list(string)::in,
                     tally::in, tally::out, io::di, io::uo) is det.

check_narrow(Name, Guard, Want, !T, !IO) :-
    Src = "schema S:\n    a: Int?\n    b: Int?\n" ++
        "rule r:\n    S s where " ++ Guard ++ "\n->\n    log info \"m\"\n",
    ( if
        built(Src, Ast),
        W = first_where(Ast),
        set.to_sorted_list(lnul_5_4_narrowed(W)) = Want
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_narrow(tally::in, tally::out, io::di, io::uo) is det.

test_narrow(!T, !IO) :-
    % [LNUL.5.2]: the guard, and the path it narrows.
    check_narrow("[LNUL.5.2] `x is not null and …` narrows x",
        "s.a is not null and s.a > 1", ["s.a"], !T, !IO),

    % [LNUL.5.4]: `not (x is null)` does not narrow.
    check_narrow("[LNUL.5.4] `not (x is null) and …` does NOT narrow",
        "not (s.a is null) and s.a > 1", [], !T, !IO),

    % `or` does not narrow: `s.a` is still `Int?` at `> 1`.
    check_narrow("[LNUL.5.4] `or` does not narrow",
        "s.a is null or s.a > 1", [], !T, !IO),

    % The positive test establishes the opposite, so it narrows nothing.
    check_narrow("[LNUL.5.4] `x is null` narrows nothing",
        "s.a is null and s.b > 1", [], !T, !IO),

    % Two guards in one conjunction, both available to the tail.
    check_narrow("[LNUL.5.2] two guards narrow two paths",
        "s.a is not null and s.b is not null and s.a > s.b",
        ["s.a", "s.b"], !T, !IO),

    % [LNUL.4.9]: `is not Int` is a tag test; only the `null` subject says
    % anything about presence.
    check_narrow("[LNUL.4.9] `is not Int` is a tag test and narrows nothing",
        "s.a is not Int and s.a > 1", [], !T, !IO),

    % A guard on something with no stable spelling narrows nothing.
    check_narrow("[LNUL.5.4] a guard on a call narrows nothing",
        "abs(s.a) is not null and s.a > 1", [], !T, !IO).

%-----------------------------------------------------------------------------%
% The dimensional checks -- [LUNI.8]
%-----------------------------------------------------------------------------%

:- pred check_dim(string::in, luni_8_3_operator::in, luni_8_7_3_dim::in,
                  luni_8_7_3_dim::in, luni_8_2_result::in,
                  tally::in, tally::out, io::di, io::uo) is det.

check_dim(Name, Op, Left, Right, Want, !T, !IO) :-
    ( if luni_8_1_combine(Op, Left, Right) = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred test_dim(tally::in, tally::out, io::di, io::uo) is det.

test_dim(!T, !IO) :-
    Temperature = decl_ref("", "temperature"),
    Length = decl_ref("", "length"),
    Celsius = dim(Temperature, yes(decl_ref("", "celsius"))),
    Kelvin = dim(Temperature, yes(decl_ref("", "kelvin"))),
    Meter = dim(Length, yes(decl_ref("", "meter"))),

    % [LUNI.8.7.4]: the check compares dimension, not scale, so celsius +
    % kelvin is valid.
    check_dim("[LUNI.8.7.4] celsius + kelvin is valid: both temperature",
        op_additive, Celsius, Kelvin, dr_ok(Celsius), !T, !IO),

    check_dim("[LUNI.8.2] temperature + length is cross-dimension",
        op_additive, Celsius, Meter,
        dr_cross_dimension(Temperature, Length), !T, !IO),

    % [LUNI.8.3]: a bare number takes no unit from the operand beside it.
    check_dim("[LUNI.8.3] a bare number beside a dimensioned value is refused",
        op_additive, Meter, dimensionless, dr_bare_number(Length), !T, !IO),

    check_dim("[LUNI.8.3] in either order",
        op_additive, dimensionless, Meter, dr_bare_number(Length), !T, !IO),

    check_dim("[LUNI.8.3] a bare number scales: n * x",
        op_multiplicative, dimensionless, Meter, dr_ok(Meter), !T, !IO),

    check_dim("[LUNI.8.3] a bare number scales: x / n",
        op_division, Meter, dimensionless, dr_ok(Meter), !T, !IO),

    check_dim("[LUNI.8.4] n / x has no dimension DS can state",
        op_division, dimensionless, Meter,
        dr_needs_annotation(Length, Length), !T, !IO),

    % [LUNI.8.4]: same dimension under `*` has no unit DS can state.
    check_dim("[LUNI.8.4] length * length is refused",
        op_multiplicative, Meter, Meter,
        dr_needs_annotation(Length, Length), !T, !IO),

    check_dim("[LUNI.8.1] a same-dimension quotient is a bare number",
        op_division, Meter, Meter, dr_ok(dimensionless), !T, !IO),

    check_dim("[LUNI.8.4] a cross-dimension quotient is refused",
        op_division, Celsius, Meter,
        dr_needs_annotation(Temperature, Length), !T, !IO),

    check_dim("[LUNI.8.1] same dimension under `+` is fine",
        op_additive, Meter, Meter, dr_ok(Meter), !T, !IO),

    % The projection that keeps `dsc.types` and `dsc.cast` in step. The
    % dimension wins over the leaf kind ([LUNI.8.7.3]); the leaf decides the
    % storage the projection carries.
    check("[LUNI.8.7.3] a unit value projects to its symbol, not to Float",
        ( if luni_8_7_3_cast_kind(ds_type(lk_float, Celsius, non_null))
                = ck_unit(decl_ref("", "celsius"), st_float)
        then yes else no ), !T, !IO),

    check("[LUNI.8.7.3] an Int-stored unit value projects with Int storage",
        ( if luni_8_7_3_cast_kind(ds_type(lk_int,
                    dim(decl_ref("", "data"), yes(decl_ref("", "bit"))), non_null))
                = ck_unit(decl_ref("", "bit"), st_int)
        then yes else no ), !T, !IO),

    check("[LUNI.8.7.3] a bare Float projects to Float",
        ( if luni_8_7_3_cast_kind(ds_type(lk_float, dimensionless, non_null))
                = ck_float
        then yes else no ), !T, !IO),

    % The same value is `temperature` to [LUNI.8] and `celsius` to
    % [LCST.4.5.1].
    check("[LCST.4.5.1] the same value casts identically to its own unit",
        ( if lcst_4_5_2_classify(
                luni_8_7_3_cast_kind(ds_type(lk_float, Celsius, non_null)),
                ct_unit(decl_ref("", "celsius"), st_float)) = cc_identity
        then yes else no ), !T, !IO),

    check("[LUNI.8.5] and strips to Float as a real conversion",
        ( if lcst_4_5_2_classify(
                luni_8_7_3_cast_kind(ds_type(lk_float, Celsius, non_null)),
                ct_float) = cc_total
        then yes else no ), !T, !IO),

    % ── a declared name becomes a static type -- [LUNI.7.1] ────────────────

    % From source, through `resolve`'s type table.
    Src = "unit dimension warmth storage float64 base therm\n" ++
        "unit celsius: warmth\n" ++
        "unit dimension currency_usd storage int64 base cent\n" ++
        "unit scalar angle storage float64\n" ++
        "schema S:\n    a: Int\n" ++
        "opaque type Handle over Bytes\n",

    check_resolved("[LUNI.7.1] a float64 unit symbol types as Float + its "
            ++ "dimension",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "celsius", E),
            luni_7_1_slot_type(RF ^ rf_unit_storage, E, non_null)
                = ds_type(lk_float, dim(decl_ref("", "warmth"), yes(decl_ref("", "celsius"))),
                    non_null)
        ), !T, !IO),

    % A slot typed with a bare dimension name ([LUNI.7.1]) has no symbol, and
    % `currency_usd` stores `int64`, so its leaf kind is `Int` ([LUNI.8.7.3]).
    check_resolved("[LUNI.7.1] a dimension name types with no symbol, as "
            ++ "its storage's kind",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "currency_usd", E),
            luni_7_1_slot_type(RF ^ rf_unit_storage, E, non_null)
                = ds_type(lk_int, dim(decl_ref("", "currency_usd"), no), non_null)
        ), !T, !IO),

    % It strips to its storage's kind and nothing else ([LUNI.8.5]).
    check_resolved("[LUNI.8.5] an int64 dimension-typed value strips to Int",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "currency_usd", E),
            T0 = luni_7_1_slot_type(RF ^ rf_unit_storage, E, non_null),
            lcst_4_5_2_classify(luni_8_7_3_cast_kind(T0), ct_int)
                = cc_total,
            lcst_4_5_2_classify(luni_8_7_3_cast_kind(T0), ct_float)
                = cc_rejected(cr_no_conversion)
        ), !T, !IO),

    % [LUNI.4.2]: a `unit scalar` group is a dimension, not `dimensionless`.
    check_resolved("[LUNI.4.2] a scalar group is its own dimension",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "angle", E),
            luni_7_1_slot_type(RF ^ rf_unit_storage, E, non_null) ^ dt_dim
                = dim(decl_ref("", "angle"), no)
        ), !T, !IO),

    check_resolved("[LUNI.7.1] a schema types as a fact, an opaque as itself",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "S", SE),
            luni_7_1_slot_type(RF ^ rf_unit_storage, SE, non_null) ^ dt_leaf
                = lk_fact("S"),
            map.search(RF ^ rf_types, "Handle", OE),
            luni_7_1_slot_type(RF ^ rf_unit_storage, OE, nullable) ^ dt_leaf
                = lk_opaque(decl_ref("", "Handle"))
        ), !T, !IO),

    check_resolved("[LGRA.22.7] a builtin types to its leaf kind",
        Src,
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "Duration", E),
            luni_7_1_slot_type(RF ^ rf_unit_storage, E, non_null)
                = ds_type(lk_duration, dim(time_dimension, no), non_null)
        ), !T, !IO),

    % [LGRA.22.8]: every generated row is in the type namespace under its own
    % name, and `resolve` reserves each.
    check_resolved("[LGRA.22.8] every builtin type row resolves to itself",
        Src,
        ( pred(RF::in) is semidet :-
            all [B] (
                list.member(B, lgra_22_8_builtin_types)
            =>
                ( map.search(RF ^ rf_types, lgra_22_8_type_name(B),
                    te_builtin(B)),
                  lgra_22_7_reserved_type(lgra_22_8_type_name(B)) )
            ),
            lgra_22_8_builtin_types = [_ | _]
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% The cast table -- [LCST.4]
%-----------------------------------------------------------------------------%
%
% `mmc`'s exhaustiveness check answers every cell; these pin the cells whose
% answer a plausible reading gets wrong.

:- pred check_cast(string::in, lcst_4_5_2_kind::in, nullability::in,
                   lcst_4_1_6_target::in, nullability::in, cast_outcome::in,
                   tally::in, tally::out, io::di, io::uo) is det.

check_cast(Name, Source, SourceNull, Target, Written, Want, !T, !IO) :-
    Got = lcst_4_cast(Source, SourceNull, Target, Written),
    ( if Got = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred check_class(string::in, lcst_4_5_2_kind::in, lcst_4_1_6_target::in,
                    lcst_4_5_2_class::in,
                    tally::in, tally::out, io::di, io::uo) is det.

check_class(Name, Source, Target, Want, !T, !IO) :-
    ( if lcst_4_5_2_classify(Source, Target) = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred test_cast(tally::in, tally::out, io::di, io::uo) is det.

test_cast(!T, !IO) :-
    % ── [LCST.4.3.1], both halves of the bijection ──────────────────────────

    check_cast("[LCST.4.3.1] a fallible conversion needs `?`",
        ck_string, non_null, ct_int, non_null,
        co_missing_q(why_conversion_fallible), !T, !IO),

    % [LCST.4.3.2]: the `?` is present if and only if the result can be null.
    check_cast("[LCST.4.3.2] a redundant `?` is equally an error",
        ck_int, non_null, ct_float, nullable, co_redundant_q, !T, !IO),

    check_cast("[LCST.4.3.1] a nullable source needs `?` even when total",
        ck_int, nullable, ct_float, non_null,
        co_missing_q(why_source_nullable), !T, !IO),

    % When both hold, the source's nullability is named.
    check_cast("[LCST.4.3.1] a nullable source outranks a fallible conversion",
        ck_string, nullable, ct_int, non_null,
        co_missing_q(why_source_nullable), !T, !IO),

    check_cast("[LCST.4.3.1] `S? ::T?` conforms and the result is nullable",
        ck_string, nullable, ct_int, nullable,
        co_ok(nullable, cs_conversion), !T, !IO),

    % ── the asymmetric pairs, which a symmetric table would get wrong ───────

    check_class("[LCST.4.5.2] `String -> Bytes` is refused (LSTR.4.6)",
        ck_string, ct_bytes, cc_rejected(cr_bytes_retired), !T, !IO),

    check_class("[LCST.4.5.2] `Bytes -> String` is refused (LSTR.4.6)",
        ck_bytes, ct_string, cc_rejected(cr_bytes_retired), !T, !IO),

    % [LCST.4.5.4]: a non-finite `Float` is a trap, "not a `null`", so the
    % conversion is total.
    check_class("[LCST.4.5.4] `Float -> Int` is total, trap not fallible",
        ck_float, ct_int, cc_total, !T, !IO),

    % ── `Json` is fact-only, in both directions and for different reasons ───

    check_class("[LCST.4.5.2] a fact converts to `Json`",
        ck_fact("Sensor"), ct_json, cc_total, !T, !IO),

    check_class("[LCST.4.5.2] a scalar does NOT convert to `Json`",
        ck_int, ct_json, cc_rejected(cr_json_not_fact), !T, !IO),

    check_class("[LCST.4.5.2] `Json` does not convert to a scalar",
        ck_json, ct_string, cc_rejected(cr_json_source), !T, !IO),

    % ── units: the one row where identity needs a comparison ────────────────

    check_class("[LCST.4.5.1] the same unit is an identity cast",
        ck_unit(decl_ref("", "celsius"), st_float), ct_unit(decl_ref("", "celsius"), st_float),
        cc_identity, !T, !IO),

    % Same-dimension values auto-convert without a cast ([LUNI.8.1]), and the
    % table has no unit-to-unit row ([LCST.4.5.3]).
    check_class("[LCST.4.5.3] a different unit is refused",
        ck_unit(decl_ref("", "celsius"), st_float), ct_unit(decl_ref("", "kelvin"), st_float),
        cc_rejected(cr_no_conversion), !T, !IO),

    check_class("[LUNI.8.5] `unit -> Float` strips the tag, total",
        ck_unit(decl_ref("", "celsius"), st_float), ct_float, cc_total, !T, !IO),

    check_class("[LUNI.8.5] `Float -> unit` asserts the tag, total",
        ck_float, ct_unit(decl_ref("", "celsius"), st_float), cc_total, !T, !IO),

    % A unit asserts from, and strips to, its dimension's storage kind and no
    % other ([LCST.4.5.2], [LUNI.8.5]).
    check_class("[LCST.4.5.2] `Int -> <int64 unit>` asserts the tag, total",
        ck_int, ct_unit(decl_ref("", "byte"), st_int), cc_total, !T, !IO),
    check_class("[LCST.4.5.2] `Float -> <int64 unit>` is refused",
        ck_float, ct_unit(decl_ref("", "byte"), st_int), cc_rejected(cr_no_conversion),
        !T, !IO),
    check_class("[LCST.4.5.2] `<int64 unit> -> Int` strips the tag, total",
        ck_unit(decl_ref("", "byte"), st_int), ct_int, cc_total, !T, !IO),
    check_class("[LCST.4.5.2] `<int64 unit> -> Float` is refused",
        ck_unit(decl_ref("", "byte"), st_int), ct_float, cc_rejected(cr_no_conversion),
        !T, !IO),
    check_class("[LCST.4.5.2] `Int -> <float64 unit>` is refused",
        ck_int, ct_unit(decl_ref("", "celsius"), st_float), cc_rejected(cr_no_conversion),
        !T, !IO),
    check_class("[LCST.4.5.2] `<float64 unit> -> Int` is refused",
        ck_unit(decl_ref("", "celsius"), st_float), ct_int, cc_rejected(cr_no_conversion),
        !T, !IO),

    % ── the refusals that carry their own reason ────────────────────────────

    check_class("[LCST.4.5.2] numeric to `Bool` is refused by name",
        ck_int, ct_bool, cc_rejected(cr_bool_numeric), !T, !IO),

    check_class("[LOPQ.4.3] an opaque value is sealed against every target",
        ck_opaque(decl_ref("", "Handle")), ct_string, cc_rejected(cr_opaque_sealed),
        !T, !IO),

    % [LCST.4.5.9]: the temporal types render their canonical text forms,
    % total; [LCST.4.5.2] with [LTIM.14]: DS reads no temporal text, so
    % `String -> Time / Date / Duration` is refused, and nothing else crosses.
    check_class("[LCST.4.5.9] `Time -> String` renders, total",
        ck_time, ct_string, cc_total, !T, !IO),
    check_class("[LCST.4.5.9] `Duration -> String` renders, total",
        ck_duration, ct_string, cc_total, !T, !IO),
    check_class("[LCST.4.5.2] `String -> Time` is refused ([LTIM.14])",
        ck_string, ct_time, cc_rejected(cr_temporal_text), !T, !IO),
    check_class("[LCST.4.5.2] `String -> Date` is refused ([LTIM.14])",
        ck_string, ct_date, cc_rejected(cr_temporal_text), !T, !IO),
    check_class("[LCST.4.5.2] `String -> Duration` is refused ([LTIM.14])",
        ck_string, ct_duration, cc_rejected(cr_temporal_text), !T, !IO),
    check_class("[LCST.4.5.1] `Date -> Date` is the identity",
        ck_date, ct_date, cc_identity, !T, !IO),
    check_class("[LCST.4.5.3] `Time -> Date` has no row and is refused",
        ck_time, ct_date, cc_rejected(cr_no_conversion), !T, !IO),
    check_class("[LCST.4.5.3] `Int -> Duration` has no row and is refused",
        ck_int, ct_duration, cc_rejected(cr_no_conversion), !T, !IO),

    % [LCST.4.5.2], [LCST.4.5.6]: `Int/Float/Bool -> String` is total.
    check_class("[LCST.4.5.6] `Int -> String` is total",
        ck_int, ct_string, cc_total, !T, !IO),

    check_class("[LCST.4.5.6] `Bool -> String` is total",
        ck_bool, ct_string, cc_total, !T, !IO),

    % [LCST.4.5.1]: legal, and the caller owes a redundant-cast warning.
    check_cast("[LCST.4.5.1] an identity cast is legal and flagged",
        ck_int, non_null, ct_int, non_null, co_ok(non_null, cs_identity),
        !T, !IO).

%-----------------------------------------------------------------------------%
% resolve -- [LGRA.22.7]'s namespaces, and [LFAC.1.7]'s identity
%-----------------------------------------------------------------------------%
%
% Each refusal is paired with a source that differs only in what the clause
% turns on.

:- pred resolved(string::in, resolved_file::out) is semidet.

resolved(Src, RF) :-
    built(Src, Ast),
    resolve_file(Ast, resolve_ok(RF)).

:- pred check_resolved(string, string, pred(resolved_file), tally, tally,
                       io, io).
:- mode check_resolved(in, in, pred(in) is semidet, in, out, di, uo) is det.

check_resolved(Name, Src, Wanted, !T, !IO) :-
    ( if resolved(Src, RF), Wanted(RF) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

    % Asserts the code, never the wording.
    %
:- pred check_resolve_error(string::in, string::in, ds_validate::in,
                            tally::in, tally::out, io::di, io::uo) is det.

check_resolve_error(Name, Src, Want, !T, !IO) :-
    ( if
        built(Src, Ast),
        resolve_file(Ast, resolve_errors(Ds)),
        list.member(D, Ds),
        D ^ dg_code = dc_validate(Want)
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- pred test_resolve(tally::in, tally::out, io::di, io::uo) is det.

test_resolve(!T, !IO) :-
    % ── the type namespace, and that it is FLAT ─────────────────────────────

    check_resolved("[LGRA.22.7] a schema and a unit both enter one table",
        "schema Sensor:\n    a: Int\n" ++
        "unit dimension span storage float64 base stride\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "Sensor", TS),
            TS = te_schema(_),
            map.search(RF ^ rf_types, "span", TL),
            TL = te_unit(uk_dimension, _)
        ), !T, !IO),

    % [LGRA.22.7]: "a schema and a unit may not both be named `celsius`".
    check_resolve_error("[LGRA.22.7] the type namespace is flat",
        "schema celsius:\n    a: Int\n" ++
        "unit scalar celsius storage float64\n",
        dv_duplicate_type_name, !T, !IO),

    % Two of a kind gets the more specific code.
    check_resolve_error("two schemas of one name are DUPLICATE_SCHEMA",
        "schema S:\n    a: Int\nschema S:\n    b: Int\n",
        dv_duplicate_schema, !T, !IO),

    check_resolve_error("[LGRA.22.7] a schema may not be named `Int`",
        "schema Int:\n    a: Int\n", dv_reserved_type_name, !T, !IO),

    % [LGRA.22.7] names the temporal types among the reserved.
    check_resolve_error("[LGRA.22.7] `Duration` is a reserved type name",
        "unit scalar Duration storage float64\n",
        dv_reserved_type_name, !T, !IO),

    % ── the value namespace at file scope ───────────────────────────────────

    check_resolved("a constant enters the value namespace",
        "const RETRY = 30\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_consts, "RETRY", _)
        ), !T, !IO),

    % [LGRA.22.7]'s two namespaces: a constant and a schema may share a name.
    check_resolved("[LGRA.22.7] a const and a schema may share one NFC name",
        "schema Reading:\n    a: Int\nconst Reading = 1\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_types, "Reading", TR),
            TR = te_schema(_),
            map.search(RF ^ rf_consts, "Reading", _)
        ), !T, !IO),

    check_resolve_error("two constants of one name collide",
        "const A = 1\nconst A = 2\n", dv_duplicate_constant, !T, !IO),

    % ── identity, computed once ─────────────────────────────────────────────

    % [LFAC.1.7.1]: the identity is the `key`-marked slots, the rest payload.
    % Declaration order is kept: the key is a tuple ([LFAC.1.7.2]), and a
    % slot's field number is its position ([LFST.8.10]).
    check_resolved("[LFAC.1.7.1] a logical schema's key is its `key` slots",
        "schema Trig scope logical:\n" ++
        "    a: Int key\n    b: Int mutable\n    c: Int key\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_identity, "Trig", Id),
            Id = id_keyed(Keys),
            list.map((func(I) = I ^ id_name), Keys) = ["a", "c"]
        ), !T, !IO),

    % [LFAC.1.7.2]: `key = ∅` is a logical schema of one live fact, not an
    % unkeyed one.
    check_resolved("[LFAC.1.7.2] an all-mutable logical schema is keyed, empty",
        "schema Single scope logical:\n    a: Int mutable\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_identity, "Single", id_keyed([]))
        ), !T, !IO),

    % [LFAC.1.7.6]: `ttl` and event facts carry no markers.
    check_resolved("[LFAC.1.7.6] a non-logical schema is unkeyed",
        "schema Ev scope ttl 30_min:\n    a: Int\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_identity, "Ev", id_unkeyed)
        ), !T, !IO),

    % [LFAC.1.7.7]: `ambient` changes who may write, never how a fact is keyed.
    check_resolved("[LFAC.1.7.7] `logical ambient` keys as `logical`",
        "schema Amb scope logical ambient:\n    a: Int key\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_identity, "Amb", IdA),
            IdA = id_keyed([_])
        ), !T, !IO),

    % ── rule scope ──────────────────────────────────────────────────────────

    check_resolved("[LLET.12.4] a rule's bindings and lets are collected",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    let x = s.a\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [Sc],
            Sc ^ rsc_rule ^ id_name = "r",
            map.search(Sc ^ rsc_bindings, "s", _),
            map.search(Sc ^ rsc_lets, "x", _)
        ), !T, !IO),

    % ── the pattern head, resolved to its schema ────────────────────────────

    % [LGRA.22.4]: a bare NAME resolving to a schema in local scope; the
    % binding carries the schema, for `typecheck`.
    check_resolved("[LGRA.22.4] a bare head resolves to the local schema",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [Sc],
            map.search(Sc ^ rsc_bindings, "s", B),
            B ^ pb_head = head_local(Schema),
            Schema ^ as_name ^ id_name = "S"
        ), !T, !IO),

    check_resolve_error("[LGRA.22.4] an unknown bare head is refused",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    Wibble w\n->\n    log info \"m\"\n",
        dv_unknown_schema, !T, !IO),

    % `resolve_file` trusts a selectively imported name; it loads no library.
    check_resolved("[LIMP.2.1.3] an imported head is trusted, not refused",
        "from ha import DoorOpen\n" ++
        "rule r:\n    DoorOpen d\n->\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [Sc],
            map.search(Sc ^ rsc_bindings, "d", B),
            B ^ pb_head = head_imported(_)
        ), !T, !IO),

    % [LGRA.22.4]: "A schema from a library is referenced only when that
    % library is imported", which this file shows.
    check_resolve_error("[LGRA.22.4] a qualified head needs its library imported",
        "rule r:\n    ha.DoorOpen d\n->\n    log info \"m\"\n",
        dv_unknown_qualifier, !T, !IO),

    check_resolved("[LGRA.22.4] and resolves when the import is there",
        "import ha\n" ++
        "rule r:\n    ha.DoorOpen d\n->\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [Sc],
            map.search(Sc ^ rsc_bindings, "d", B),
            B ^ pb_head = head_qualified(_, _)
        ), !T, !IO),

    % [LGRA.22.9]: a binding never shadows a library, so `ha.x` has one
    % reading. Each of the three kinds, and the first segment of a dotted
    % path, and an alias.
    check_resolve_error("[LGRA.22.9] a pattern binding may not shadow a library",
        "import ha\n" ++
        "rule r:\n    ha.DoorOpen ha\n->\n    log info \"m\"\n",
        dv_binding_shadows_library, !T, !IO),

    check_resolve_error("[LGRA.22.9] a `let` may not shadow a library",
        "import ha\n" ++
        "rule r:\n    ha.DoorOpen d\n->\n    let ha = 1\n    log info \"m\"\n",
        dv_binding_shadows_library, !T, !IO),

    check_resolve_error("[LGRA.22.9] a constant may not shadow a library",
        "import ha\nconst ha = 1\n",
        dv_binding_shadows_library, !T, !IO),

    check_resolve_error("[LGRA.22.9] the first segment of a path is held",
        "import units.si\n" ++
        "rule r:\n    units.si.S units\n->\n    log info \"m\"\n",
        dv_binding_shadows_library, !T, !IO),

    check_resolve_error("[LGRA.22.9] an alias is held",
        "import units.si as u\n" ++
        "rule r:\n    u.S u\n->\n    log info \"m\"\n",
        dv_binding_shadows_library, !T, !IO),

    % The alias replaces the path, so the path's first segment is free.
    check_resolved("[LGRA.22.9] an aliased path's first segment is free",
        "import units.si as u\n" ++
        "rule r:\n    u.S units\n->\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [_]
        ), !T, !IO),

    check_resolve_error("two patterns binding one name collide",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n    S s\n->\n    log info \"m\"\n",
        dv_duplicate_binding, !T, !IO),

    check_resolve_error("[LLET.12.4] a `let` may not shadow a binding",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    let s = 1\n    log info \"m\"\n",
        dv_let_shadows_binding, !T, !IO),

    check_resolve_error("[LLET.12.4] a `let` may not shadow a constant",
        "schema S:\n    a: Int\nconst LIMIT = 5\n" ++
        "rule r:\n    S s\n->\n    let LIMIT = 1\n    log info \"m\"\n",
        dv_let_shadows_constant, !T, !IO),

    check_resolve_error("[LLET.12.4] two `let`s of one name collide",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    let x = 1\n    let x = 2\n" ++
        "    log info \"m\"\n",
        dv_duplicate_let, !T, !IO),

    % [LGRA.22.7]'s value-namespace reservation: resolution runs binding →
    % constant → builtin.
    check_resolve_error("[LGRA.22.7] a binding may not be named `abs`",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S abs\n->\n    log info \"m\"\n",
        dv_reserved_builtin_name, !T, !IO),

    % The reserved set includes the quantiles `p1`..`p99` ([LSER.17.6]), as
    % spelled: `p01` is not one.
    check_resolve_error("[LSER.17.6] `p95` is reserved",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    let p95 = 1\n    log info \"m\"\n",
        dv_reserved_builtin_name, !T, !IO),

    check_resolved("[LSER.17.6] `p01` is NOT a builtin name",
        "schema S:\n    a: Int\n" ++
        "rule r:\n    S s\n->\n    let p01 = 1\n    log info \"m\"\n",
        ( pred(RF::in) is semidet :-
            RF ^ rf_scopes = [Sc],
            map.search(Sc ^ rsc_lets, "p01", _)
        ), !T, !IO),

    check_resolved("[LUNI.4.3] unit aliases are recorded against the symbol",
        "unit degree: angle = x * 2 label \"deg\" alias deg, °\n",
        ( pred(RF::in) is semidet :-
            map.search(RF ^ rf_unit_alias, "deg", C),
            C ^ id_name = "degree",
            map.search(RF ^ rf_unit_alias, "°", _)
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% Units -- [LUNI.4]
%-----------------------------------------------------------------------------%

:- func one_ast_unit(ast_file) = ast_unit.
:- mode one_ast_unit(in) = out is semidet.

one_ast_unit(ast_file(_, [ad_unit(U)])) = U.

:- pred test_unit(tally::in, tally::out, io::di, io::uo) is det.

test_unit(!T, !IO) :-
    % These parse and build and bind no name, so they may spell a
    % `units.core` declaration: [LIMP.5.1.5]'s refusal is `resolve`'s.
    %
    % ── `unit dimension` and `unit scalar` ──────────────────────────────────

    check_built("[LUNI.4.1] a dimension carries storage and a base unit",
        "unit dimension length storage float64 base meter\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_dimension(N, S, B, _, _),
            N ^ id_name = "length",
            S ^ id_name = "float64",
            B ^ id_name = "meter"
        ), !T, !IO),

    % The base may be a glyph symbol ([LUNI.3.2]), a `type_sym` ([LLEX.10.2]).
    check_built("[LUNI.4.1] a glyph base symbol is admitted",
        "unit dimension temperature storage float64 base °C\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_dimension(_, _, B, _, _),
            B ^ id_name = "°C"
        ), !T, !IO),

    % The parser does not narrow the storage type; [LUNI.4.1.1]'s three
    % values are not a parse rule.
    check_parse("[LUNI.4.1.1] an unknown storage type still parses",
        "unit dimension length storage flaot64 base meter\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_unit(ud_dimension(_, S, _, _))],
            S ^ id_name = "flaot64"
        ), !T, !IO),

    check_built("[LUNI.4.2] a scalar takes an optional label",
        "unit scalar dB storage float64 label \"generic decibel\"\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_scalar(N, _, yes("generic decibel"), _, _),
            N ^ id_name = "dB"
        ), !T, !IO),

    % ── `unit <symbol>: <dimension>` and its three bodies ───────────────────

    check_built("[LUNI.4.3] a base unit has no body",
        "unit meter: length\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_symbol(Sym, Dim, aub_base, no, [], _, _, _),
            Sym ^ id_name = "meter",
            Dim ^ id_name = "length"
        ), !T, !IO),

    % The affine body's span stops at `label` and `alias`.
    check_built("[LUNI.4.3] an affine body does not swallow label or alias",
        "unit celsius: temperature = x + 273.15 label \"°C\" alias °C\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_symbol(Sym, _, aub_affine(_), Label, Aliases,
                _, _, _),
            Sym ^ id_name = "celsius",
            Label = yes("°C"),
            list.map((func(I) = I ^ id_name), Aliases) = ["°C"]
        ), !T, !IO),

    check_built("[LUNI.4.3] `alias` takes a comma list",
        "unit degree: angle = x * pi / 180 label \"deg\" alias deg, °\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_symbol(_, _, aub_affine(_), _, Aliases, _, _, _),
            list.map((func(I) = I ^ id_name), Aliases) = ["deg", "°"]
        ), !T, !IO),

    % [LUNI.4.3]'s tier-2 block: both directions, in order.
    check_built("[LUNI.4.3] a tier-2 block takes to_base and from_base",
        "unit sone: loudness:\n" ++
        "    to_base: 2.0 ** ((x - 40.0) / 10.0)\n" ++
        "    from_base: 10.0 * x + 40.0\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_symbol(Sym, _, aub_tier2(_, _, _), _, _, _, _, _),
            Sym ^ id_name = "sone"
        ), !T, !IO),

    % `dimension` names a form only when no `:` follows it. The word is
    % reserved ([LLEX.9.6]); this pins only the parse.
    check_built("a unit symbol may be spelled `dimension`",
        "unit dimension: length\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_symbol(Sym, Dim, aub_base, _, _, _, _, _),
            Sym ^ id_name = "dimension",
            Dim ^ id_name = "length"
        ), !T, !IO),

    % ── refusals ────────────────────────────────────────────────────────────

    % [LUNI.4.5]: the single-formula spelling is named, not an unexpected
    % `(`.
    check_parse_error("[LUNI.4.5] the single-formula form is named",
        "unit formula midi_to_hz(x: midi_note): Hz = 1\n",
        pe_formula_not_pair, !T, !IO),

    % So is a `pair` keyword.
    check_parse_error("[LUNI.4.5] a `pair` keyword is named",
        "unit formula pair hz_period inverting implicit:\n" ++
        "    hz_to_period(x: Hz): nanosecond  = 1e9 / x\n" ++
        "    period_to_hz(x: nanosecond): Hz  = 1e9 / x\n",
        pe_formula_pair_keyword, !T, !IO),

    % [LLEX.9.6] does not reserve `pair`, so a formula may be called it.
    check_built("[LUNI.4.5] a formula may be named `pair`",
        "unit formula pair implicit:\n" ++
        "    fwd(x: Hz): nanosecond  = 1e9 / x\n" ++
        "    bwd(x: nanosecond): Hz  = 1e9 / x\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_formula(N, [afm_implicit(_)], [_, _], _),
            N ^ id_name = "pair"
        ), !T, !IO),

    % [LUNI.4.5]: each modifier "appears at most once".
    check_parse_error("[LUNI.4.5] a repeated modifier is refused",
        "unit formula hz_period implicit implicit:\n" ++
        "    hz_to_period(x: Hz): nanosecond  = 1e9 / x\n" ++
        "    period_to_hz(x: nanosecond): Hz  = 1e9 / x\n",
        pe_formula_modifier_repeated("implicit"), !T, !IO),

    % ── the two conformance sources ─────────────────────────────────────────

    % `LUNI.4.5.1_implicit_at_where_ok.json`'s unit declarations, verbatim.
    check_built("[LUNI.4.5] a formula takes both modifiers and two lines",
        "unit formula hz_period inverting implicit:\n" ++
        "    hz_to_period(x: Hz): nanosecond  = 1e9 / x\n" ++
        "    period_to_hz(x: nanosecond): Hz  = 1e9 / x\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_formula(N, Mods, Lines, _),
            N ^ id_name = "hz_period",
            Mods = [afm_inverting(_), afm_implicit(_)],
            Lines = [L1, L2],
            L1 ^ afl_name ^ id_name = "hz_to_period",
            L1 ^ afl_param ^ id_name = "x",
            L1 ^ afl_param_type ^ id_name = "Hz",
            L1 ^ afl_return ^ id_name = "nanosecond",
            L2 ^ afl_return ^ id_name = "Hz"
        ), !T, !IO),

    % [LUNI.4.6]'s worked example, verbatim. The selector is the `where`
    % grammar; `DS_VALIDATE_FX_PAIR_SELECTOR` restricts it.
    check_built("[LUNI.4.6] an fx_pair takes via, where and field",
        "unit fx_pair USD_to_EUR: currency_usd to currency_eur\n" ++
        "    via FxRate where base_code == \"USD\" and quote_code == \"EUR\"\n" ++
        "    field rate_num / rate_den\n",
        ( pred(F::in) is semidet :-
            one_ast_unit(F) = au_fx_pair(N, From, To, Via, _, Num, Den, _),
            N ^ id_name = "USD_to_EUR",
            From ^ id_name = "currency_usd",
            To ^ id_name = "currency_eur",
            Via ^ id_name = "FxRate",
            Num ^ id_name = "rate_num",
            Den ^ id_name = "rate_den"
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% Imports -- [LIMP.2]
%-----------------------------------------------------------------------------%

:- func one_ast_import(ast_file) = ast_import.
:- mode one_ast_import(in) = out is semidet.

one_ast_import(ast_file(_, [ad_import(I)])) = I.

:- func segments(list(ident)) = list(string).

segments(Is) = list.map((func(I) = I ^ id_name), Is).

:- pred test_import(tally::in, tally::out, io::di, io::uo) is det.

test_import(!T, !IO) :-
    % ── the two forms ───────────────────────────────────────────────────────

    check_built("[LIMP.2.1.2] `import ha` is a qualified import of one segment",
        "import ha\n",
        ( pred(F::in) is semidet :-
            I = one_ast_import(F),
            segments(I ^ ai_path) = ["ha"],
            I ^ ai_form = aif_qualified(no, "ha")
        ), !T, !IO),

    % [LIMP.2.1.4] / [LIMP.2.4.3]: dotted paths, to any depth.
    check_built("[LIMP.2.4.3] a three-segment path keeps all three segments",
        "import adapters.aws.s3\n",
        ( pred(F::in) is semidet :-
            segments(one_ast_import(F) ^ ai_path) = ["adapters", "aws", "s3"]
        ), !T, !IO),

    check_built("[LIMP.2.1.3] `from ha import light, switch` binds two names",
        "from ha import light, switch\n",
        ( pred(F::in) is semidet :-
            I = one_ast_import(F),
            segments(I ^ ai_path) = ["ha"],
            I ^ ai_form = aif_selective([A, B]),
            A ^ aii_binding = "light",
            B ^ aii_binding = "switch"
        ), !T, !IO),

    % ── the binding, which is the one thing `build` decides ─────────────────

    % [LIMP.2.1.4]: the qualifier is the whole path, `units.si.meter`.
    check_built("[LIMP.2.1.4] the derived qualifier is the whole dotted path",
        "import units.si\n",
        ( pred(F::in) is semidet :-
            one_ast_import(F) ^ ai_form = aif_qualified(no, "units.si")
        ), !T, !IO),

    % [LIMP.2.1.7]: "`import units.si as u` binds the qualifier `u`."
    check_built("[LIMP.2.1.7] an alias replaces the derived qualifier",
        "import units.si as u\n",
        ( pred(F::in) is semidet :-
            I = one_ast_import(F),
            I ^ ai_form = aif_qualified(yes(_), "u"),
            % The path is still two segments; `as` is not a third.
            segments(I ^ ai_path) = ["units", "si"]
        ), !T, !IO),

    check_built("[LIMP.2.1.7] a per-name alias replaces that name's binding",
        "from b import Sensor as BSensor\n",
        ( pred(F::in) is semidet :-
            one_ast_import(F) ^ ai_form = aif_selective([A]),
            A ^ aii_name ^ id_name = "Sensor",
            A ^ aii_binding = "BSensor"
        ), !T, !IO),

    % The alias is kept beside the binding, for
    % `DS_VALIDATE_IMPORT_NAME_COLLISION`.
    check_built("[LIMP.2.1.7] an unaliased import records the absence",
        "from b import Sensor\n",
        ( pred(F::in) is semidet :-
            one_ast_import(F) ^ ai_form = aif_selective([A]),
            A ^ aii_alias = no,
            A ^ aii_binding = "Sensor"
        ), !T, !IO),

    % ── the list forms ──────────────────────────────────────────────────────

    % [LIMP.2.2.2]: "`from ha import a,` and `from ha import (a,)` are equally
    % legal."
    check_parse("[LIMP.2.2.2] a trailing comma is legal unparenthesised",
        "from ha import a,\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_import(limp_2_1_1_selective(_, [_], _))]
        ), !T, !IO),

    % [LIMP.2.2.1] rests on brackets suspending both newline and indentation
    % ([LLEX.7.3], [LLEX.6.4]).
    check_parse("[LIMP.2.2.1] the parenthesised form spans lines",
        "from ha import (\n    AlarmTriggered,\n    DoorOpen,\n    light,\n)\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_import(limp_2_1_1_selective(_, Items, _))],
            length(Items) = 3
        ), !T, !IO),

    % ── refusals ────────────────────────────────────────────────────────────

    % [LIMP.2.4.2]: refused by name.
    check_parse_error("[LIMP.2.4.2] `from ha import *` names the form",
        "from ha import *\n", pe_import_wildcard, !T, !IO),

    % [LIMP.2.1.1]: `import_item (',' import_item)*`, so one name is the
    % minimum.
    check_parse_error("[LIMP.2.1.1] an empty selective list is a parse error",
        "from ha import\n", pe_empty_import_list, !T, !IO),

    % `DS_PARSE_DUPLICATE_USE`, a parse error; no `DS_VALIDATE_*` code exists
    % for it.
    check_parse_error("a second `use` directive is a parse error",
        "use core\nuse other\n", pe_duplicate_use(pos(1, 0)), !T, !IO),

    % ── placement: the two conformance sources ──────────────────────────────

    % `LIMP.2.3.2`'s fixture source: imports and declarations are one ordered
    % list, which the validator reads.
    check_parse("[LIMP.2.3.2] an import after a declaration parses, in order",
        "schema Trig scope logical:\n    v: Int key\n\nimport some_lib\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_schema(_), td_import(_)]
        ), !T, !IO),

    % `LIMP.2.3.3`'s fixture source: a `use` after an import parses, so
    % `validate` can refuse it.
    check_parse("[LIMP.2.3.3] a `use` after an import parses, and is recorded",
        "import ha\n\nuse default\n\nschema Trig scope logical:\n    v: Int key\n",
        ( pred(F::in) is semidet :-
            F ^ f_use = yes(U),
            U ^ u_base ^ id_name = "default",
            F ^ f_decls = [td_import(_), td_schema(_)]
        ), !T, !IO).

%-----------------------------------------------------------------------------%
% TYPE_SYM -- [LLEX.10.2]
%-----------------------------------------------------------------------------%
%
% [LLEX.12.2]'s glyphs and their confusables, against the vendored Unicode
% data; only the third group stays a `name` ([LNAM.2.2.1]):
%
%   not XID                 ° U+00B0, ′ U+2032, ″ U+2033
%   XID, not `Allowed`      µ U+00B5, ₙ U+2099, Ω U+2126, ʹ U+02B9,
%                           ʺ U+02BA, Å U+212B
%   XID and `Allowed`       Ω U+03A9, Å U+00C5, μ U+03BC
%
% [LNAM.2.2.4] says `µ` "may appear in an identifier"; U+00B5 is not
% `Allowed`. These cases follow the data.

:- pred test_type_sym(tally::in, tally::out, io::di, io::uo) is det.

test_type_sym(!T, !IO) :-
    Deg = from_char(det_from_int(0x00B0)),      % ° DEGREE SIGN, not XID
    Micro = from_char(det_from_int(0x00B5)),    % µ MICRO SIGN, XID not Allowed
    Prime = from_char(det_from_int(0x2032)),    % ′ PRIME, not XID
    Ohm = from_char(det_from_int(0x03A9)),      % Ω GREEK CAPITAL OMEGA, legal
    Mu = from_char(det_from_int(0x03BC)),       % μ GREEK SMALL MU, XID+Allowed
    OhmSign = from_char(det_from_int(0x2126)),  % Ω OHM SIGN, NFC -> U+03A9
    SubN = from_char(det_from_int(0x2099)),     % ₙ, continuation only

    % ── glyph runs ──────────────────────────────────────────────────────────

    check_toks("[LLEX.10.2] `°C` lexes as a type_sym", Deg ++ "C",
        [type_sym(Deg ++ "C")], !T, !IO),

    check_toks("[LLEX.10.2] `µs` lexes as a type_sym", Micro ++ "s",
        [type_sym(Micro ++ "s")], !T, !IO),

    % A glyph mid-run: `m′` cannot be classified from its first character.
    check_toks("[LLEX.10.2] a glyph mid-run still makes one token",
        "m" ++ Prime, [type_sym("m" ++ Prime)], !T, !IO),

    % ── what stays a name ───────────────────────────────────────────────────

    % U+03A9 and U+03BC are XID and `Allowed`, so a run of only them is a
    % name. Both Greek: [LNAM.2.5.1] refuses a Greek+Latin mixture.
    check_toks("[LNAM.2.2.1] a name of `Allowed` glyphs stays a name",
        Ohm ++ Mu, [name(Ohm ++ Mu)], !T, !IO),

    check_toks("[LLEX.10.5] a plain identifier is untouched", "entity_id",
        [name("entity_id")], !T, !IO),

    % Classified on the NFC form: OHM SIGN normalises to GREEK CAPITAL OMEGA.
    check_toks("[LNAM.2.2.3] OHM SIGN normalises into a name",
        OhmSign ++ Mu, [name(Ohm ++ Mu)], !T, !IO),

    % ── the fold ────────────────────────────────────────────────────────────

    % [LLEX.12.2.1] folds four look-alikes on a type_sym, which can only
    % resolve as a unit symbol ([LNAM.2.3.2]).
    check_toks("[LLEX.12.2.1] a type_sym's confusables are folded",
        from_char(det_from_int(0x02B9)) ++ "x",
        [type_sym(Prime ++ "x")], !T, !IO),

    % ── the glyph that opens nothing ────────────────────────────────────────

    % [LUNI.3.2] makes U+2099 continuation-only, matching the unit-suffix
    % scanner. It is still admitted inside a run.
    check_toks("[LUNI.3.2] `ₙ` is admitted inside a run", "g" ++ SubN,
        [type_sym("g" ++ SubN)], !T, !IO),

    % ── the isolation, which is grammatical ─────────────────────────────────

    % [LLEX.10.8.3]: the lexer emits the token unconditionally and the grammar
    % accepts it in type position only.
    check_parse("[LLEX.10.2] a glyph type in a slot declaration parses",
        "schema S:\n    t: " ++ Deg ++ "C\n",
        ( pred(F::in) is semidet :-
            S = one_schema(F),
            S ^ sd_fields = [Fld],
            Fld ^ fd_type ^ id_name = Deg ++ "C"
        ), !T, !IO),

    check_parse_fails("[LLEX.10.8.3] a glyph OUTSIDE a type position is refused",
        "schema " ++ Deg ++ "C:\n    t: Int\n", !T, !IO),

    % [LLEX.12.2] closes the set.
    check_lex_error("[LLEX.12.2] a non-unit non-XID character is refused",
        "x = " ++ from_char(det_from_int(0x20AC)),
        lx_bad_char(det_from_int(0x20AC)), !T, !IO).

    % Asserts a source lexes but does not parse; a lex error fails it.
    %
:- pred check_parse_fails(string::in, string::in,
                          tally::in, tally::out, io::di, io::uo) is det.

check_parse_fails(Name, Src, !T, !IO) :-
    llex_5_4_lex(Src, LexResult),
    (
        LexResult = lex_error(E, _),
        Ok = no,
        io.format("    lexing failed, so the parser was never reached: %s\n",
            [s(describe_lex_error(E))], !IO)
    ;
        LexResult = lex_ok(Lines),
        llex_6_2_layout(Lines, LayResult),
        ( if
            LayResult = lay_ok(Toks),
            lgra_3_1_parse(Toks, parse_error(_, _))
        then
            Ok = yes
        else
            Ok = no
        )
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% Bidi controls in strings and comments -- [LNAM.2.6.3]
%-----------------------------------------------------------------------------%
%
% Trojan Source (CVE-2021-42574): a scoping control left open in a literal or
% comment reorders the source around it. The nine scoping controls are every
% codepoint `UnicodeData.txt` gives a scoping `Bidi_Class`; `LRM`, `RLM` and
% `ALM` are classes `L`, `R` and `AL`, none scoping. The walk follows UAX #9,
% not strict nesting.

    %@helper
:- func bidi(int) = string.

bidi(Cp) = from_char(det_from_int(Cp)).

    % A `lex_error` and its position: the control is invisible, so the column
    % is the diagnostic.
    %
:- pred check_lex_error_at(string::in, string::in, lex_error::in, pos::in,
                           tally::in, tally::out, io::di, io::uo) is det.

check_lex_error_at(Name, Src, Want, WantPos, !T, !IO) :-
    llex_5_4_lex(Src, Result),
    ( if Result = lex_error(Want, WantPos) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred test_bidi(tally::in, tally::out, io::di, io::uo) is det.

test_bidi(!T, !IO) :-
    LRE = bidi(0x202A),
    RLE = bidi(0x202B),
    PDF = bidi(0x202C),
    RLO = bidi(0x202E),
    LRI = bidi(0x2066),
    RLI = bidi(0x2067),
    PDI = bidi(0x2069),
    LRM = bidi(0x200E),
    RLM = bidi(0x200F),
    ALM = bidi(0x061C),

    % ── the attack, in a comment ────────────────────────────────────────────

    check_lex_error("[LNAM.2.6.3] an unclosed override in a comment is refused",
        "# " ++ RLO ++ " not really a comment\nx = 1\n",
        lx_bidi_unterminated(bw_comment, det_from_int(0x202E)), !T, !IO),

    % The position is the control's own: column 2, not the comment's start.
    check_lex_error_at("[LNAM.2.6.3] the fault is reported at the control",
        "# " ++ RLO ++ " x\n",
        lx_bidi_unterminated(bw_comment, det_from_int(0x202E)),
        pos(1, 2), !T, !IO),

    % ── the attack, in a string ─────────────────────────────────────────────

    check_lex_error("[LNAM.2.6.3] an unclosed override in a string is refused",
        "x = \"" ++ RLO ++ "abc\"\n",
        lx_bidi_unterminated(bw_string, det_from_int(0x202E)), !T, !IO),

    check_lex_error("[LNAM.2.6.3] an unclosed isolate in a string is refused",
        "x = \"" ++ LRI ++ "abc\"\n",
        lx_bidi_unterminated(bw_string, det_from_int(0x2066)), !T, !IO),

    check_lex_error("[LNAM.2.6.3] `\"\"\"` content is scanned too",
        "x = \"\"\"\nline one\n" ++ RLE ++ "line two\n\"\"\"\n",
        lx_bidi_unterminated(bw_string, det_from_int(0x202B)), !T, !IO),

    % The outermost opener is named.
    check_lex_error("[LNAM.2.6.3] two left open names the outer one",
        "# " ++ RLE ++ LRI ++ " x\n",
        lx_bidi_unterminated(bw_comment, det_from_int(0x202B)), !T, !IO),

    % ── the other word: `unbalanced`, a close that closes nothing ───────────

    % [LNAM.2.6.3]: "an unbalanced or unterminated bidi control sequence"; a
    % pop that closes nothing is the first.
    check_lex_error("[LNAM.2.6.3] a `PDF` closing nothing is refused",
        "x = \"" ++ PDF ++ "abc\"\n",
        lx_bidi_unmatched(bw_string, det_from_int(0x202C)), !T, !IO),

    check_lex_error("[LNAM.2.6.3] a `PDI` closing nothing is refused",
        "# " ++ PDI ++ " x\n",
        lx_bidi_unmatched(bw_comment, det_from_int(0x2069)), !T, !IO),

    % UAX #9 X7: a `PDF` does not close an isolate.
    check_lex_error("[LNAM.2.6.3] a `PDF` does not close an isolate",
        "x = \"" ++ RLI ++ PDF ++ PDI ++ "\"\n",
        lx_bidi_unmatched(bw_string, det_from_int(0x202C)), !T, !IO),

    % ── what is admitted ────────────────────────────────────────────────────

    % [LNAM.2.6.3]: "the legitimate way to embed an LTR run inside RTL string
    % data".
    check_lex_error_free("[LNAM.2.6.3] a balanced embedding is legal",
        "x = \"" ++ RLE ++ "abc" ++ PDF ++ "\"\n", !T, !IO),

    check_lex_error_free("[LNAM.2.6.3] a balanced isolate is legal",
        "x = \"" ++ RLI ++ "abc" ++ PDI ++ "\"\n", !T, !IO),

    % UAX #9 X6a: a `PDI` terminates its isolate and every embedding opened
    % inside it, so no `PDF` is required.
    check_lex_error_free("[LNAM.2.6.3] `RLI LRE PDI` needs no `PDF` (UAX #9 X6a)",
        "x = \"" ++ RLI ++ LRE ++ "abc" ++ PDI ++ "\"\n", !T, !IO),

    check_lex_error_free("[LNAM.2.6.3] properly nested controls are legal",
        "x = \"" ++ RLE ++ LRI ++ "abc" ++ PDI ++ PDF ++ "\"\n", !T, !IO),

    % The non-scoping marks open no scope, and are permitted.
    check_lex_error_free("[LNAM.2.6.3] LRM / RLM / ALM are permitted",
        "x = \"" ++ LRM ++ "a" ++ RLM ++ "b" ++ ALM ++ "\"\n", !T, !IO),

    % [LNAM.2.6.1]: strong RTL letters are unrestricted; the rules constrain
    % the controls only.
    check_lex_error_free("[LNAM.2.6.1] RTL letters need no controls and are legal",
        "x = \"مستشعر\"\n# مستشعر\n", !T, !IO),

    % [LLEX.5.1]: a comment with no controls leaves its line blank.
    check_lines("[LLEX.5.1] a plain comment is a blank line",
        "# just a comment\nx = 1\n", 1, !T, !IO).

    % Asserts a source lexes.
    %
:- pred check_lex_error_free(string::in, string::in,
                             tally::in, tally::out, io::di, io::uo) is det.

check_lex_error_free(Name, Src, !T, !IO) :-
    llex_5_4_lex(Src, Result),
    (
        Result = lex_ok(_),
        Ok = yes
    ;
        Result = lex_error(E, _),
        Ok = no,
        io.format("    refused: %s\n", [s(describe_lex_error(E))], !IO)
    ),
    check(Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
% The parser, end to end
%-----------------------------------------------------------------------------%

    % Source text all the way to a CST, through the three passes.
    %
:- pred front(string::in, file::out) is semidet.

front(Src, File) :-
    llex_5_4_lex(Src, lex_ok(Lines)),
    llex_6_2_layout(Lines, lay_ok(Toks)),
    lgra_3_1_parse(Toks, parse_ok(File)).

    % Types only in the `:- pred`, modes only in the `:- mode`: a higher-order
    % argument cannot carry an inline `::in`.
    %
:- pred check_parse(string, string, pred(file), tally, tally, io, io).
:- mode check_parse(in, in, pred(in) is semidet, in, out, di, uo) is det.

check_parse(Name, Src, Wanted, !T, !IO) :-
    ( if front(Src, File), Wanted(File) then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred check_parse_error(string::in, string::in, parse_error::in,
                          tally::in, tally::out, io::di, io::uo) is det.

check_parse_error(Name, Src, Want, !T, !IO) :-
    ( if
        llex_5_4_lex(Src, lex_ok(Lines)),
        llex_6_2_layout(Lines, lay_ok(Toks)),
        lgra_3_1_parse(Toks, parse_error(Want, _))
    then
        Ok = yes
    else
        Ok = no
    ),
    check(Name, Ok, !T, !IO).

:- func one_schema(file) = lgra_5_1_schema_decl.
:- mode one_schema(in) = out is semidet.

one_schema(file(_, [td_schema(S)])) = S.

:- pred test_parse(tally::in, tally::out, io::di, io::uo) is det.

test_parse(!T, !IO) :-
    Simple = "schema Sensor:\n    entity_id: String key\n    state: Float?\n",

    check_parse("a schema parses to two fields", Simple,
        ( pred(F::in) is semidet :-
            S = one_schema(F),
            S ^ sd_name ^ id_name = "Sensor",
            length(S ^ sd_fields) = 2
        ), !T, !IO),

    % [LGRA.5.1]'s `NULLABLE?`.
    check_parse("`state: Float?` is nullable and `entity_id` is not", Simple,
        ( pred(F::in) is semidet :-
            S = one_schema(F),
            S ^ sd_fields = [A, B],
            A ^ fd_nullable = non_null,
            B ^ fd_nullable = nullable,
            B ^ fd_type ^ id_name = "Float"
        ), !T, !IO),

    % `key` is a marker only in marker position ([LLEX.17.6]). The name is
    % reserved ([LLEX.9.6]) and `validate` refuses it ([LLEX.9.5]); this pins
    % the parse.
    check_parse("a slot named `key` and marked `key` parses",
        "schema S:\n    key: String key\n",
        ( pred(F::in) is semidet :-
            S = one_schema(F),
            S ^ sd_fields = [Fld],
            Fld ^ fd_name ^ id_name = "key",
            Fld ^ fd_markers = [sm_key(_)]
        ), !T, !IO),

    % [LGRA.5.2]: the lgra_5_2_lifecycle clause sits AFTER the name and BEFORE the `:`.
    check_parse("[LGRA.5.2] `scope activation` is recorded",
        "schema S scope activation:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_lifecycle = maybe.yes(lc_activation)
        ), !T, !IO),

    check_parse("`scope logical ambient` carries the ambient flag",
        "schema S scope logical ambient:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_lifecycle = maybe.yes(lc_logical(ambient))
        ), !T, !IO),

    % Absent is recorded as absent; `build` applies [LSCP.1.4]'s default.
    check_parse("an omitted lgra_5_2_lifecycle stays `no`, not `explicit`", Simple,
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_lifecycle = maybe.no
        ), !T, !IO),

    % [LGRA.5.1]'s optional leading `docstring?`.
    check_parse("a docstring is taken, and the fields still parse",
        "schema S:\n    \"what it is\"\n    a: Int\n",
        ( pred(F::in) is semidet :-
            S = one_schema(F),
            S ^ sd_doc = maybe.yes("what it is"),
            length(S ^ sd_fields) = 1
        ), !T, !IO),

    % [LGRA.3.1]: `use NAME NEWLINE`, or `use NAME ':'` and an indented block
    % of `NAME ':' BOOL_LIT` lines.
    check_parse("`use ha:` takes a base and its setting lines",
        "use ha:\n    realtime: true\n    linear_scan: false\n"
            ++ "schema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            F ^ f_use = maybe.yes(U),
            U ^ u_base ^ id_name = "ha",
            U ^ u_settings = [setting_line(R, yes), setting_line(L, no)],
            R ^ id_name = "realtime",
            L ^ id_name = "linear_scan"
        ), !T, !IO),
    check_parse("a bare `use ha` has no settings",
        "use ha\nschema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            F ^ f_use = maybe.yes(U),
            U ^ u_settings = []
        ), !T, !IO),
    % A repeated line parses: [LDIA.3.3.6] refuses it with a code of its own,
    % which a parse error could not carry.
    check_parse("a capability set twice still parses",
        "use ha:\n    regex: true\n    regex: false\nschema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            F ^ f_use = maybe.yes(U),
            length(U ^ u_settings) = 2
        ), !T, !IO),
    check_parse_error("a `+` chain is refused by name",
        "use ha +realtime\nschema S:\n    a: Int\n",
        pe_use_plus_chain, !T, !IO),
    check_parse_error("a parenthesised list is refused by name",
        "use ha (realtime)\nschema S:\n    a: Int\n",
        pe_use_paren_group, !T, !IO),
    check_parse_error("`use ha:` with no block is refused",
        "use ha:\n\nschema S:\n    a: Int\n",
        pe_use_empty_block, !T, !IO),
    check_parse_error("a setting that is not `true` or `false` is refused",
        "use ha:\n    regex: yes\nschema S:\n    a: Int\n",
        pe_expected("`true` or `false`", name("yes")), !T, !IO),

    % `service` is a top-level declaration, though [LGRA.3.1] does not list it.
    check_parse("a `service` declaration sits beside a `schema`",
        "service slack:\n    kwarg url: String\n    no response\n"
            ++ "schema S:\n    a: Int\n",
        ( pred(F::in) is semidet :-
            F ^ f_decls = [td_service(S), td_schema(_)],
            S ^ sv_name = [ident("slack", _)]
        ), !T, !IO),

    % [LGRA.5.1]: `field_decl+`, so a grammar error, naming the schema.
    check_parse_error("[LGRA.5.1] a schema with no fields is a parse error",
        "schema S:\n    \"only a docstring\"\n",
        pe_empty_schema("S"), !T, !IO),

    check_parse_error("a stray word at the top level is named",
        "wibble x\n", pe_unknown_decl("wibble"), !T, !IO),

    % [LGRA.5.1]'s markers: `retained`, `key`, `mutable`.
    check_parse("[LGRA.5.1] `retained` and `key` are markers",
        "schema S:\n    a: Float retained key\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_fields = [Fld],
            Fld ^ fd_markers = [sm_retained(_), sm_key(_)]
        ), !T, !IO),
    check_parse_fails("`sampled` is not a marker",
        "schema S:\n    a: Float sampled\n", !T, !IO),

    % A tolerance takes one numeric literal, so a docstring after it is kept.
    check_parse("`tolerance 0.5` does not swallow the trailing docstring",
        "schema S:\n    a: Float tolerance 0.5 \"how close\"\n",
        ( pred(F::in) is semidet :-
            one_schema(F) ^ sd_fields = [Fld],
            Fld ^ fd_tolerance = maybe.yes(_),
            Fld ^ fd_doc = maybe.yes("how close")
        ), !T, !IO).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
% Unicode -- identifiers, mixed script, NFC
%-----------------------------------------------------------------------------%

    % Mercury spells a codepoint escape `\xHEX\`, hex digits terminated by a
    % backslash.
    %
:- pred check_nfc(string::in, string::in, string::in,
                  tally::in, tally::out, io::di, io::uo) is det.

check_nfc(Name, In, Want, !T, !IO) :-
    ( if lnam_2_4_1_nfc(In) = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred check_hr(string::in, string::in, bool::in,
                 tally::in, tally::out, io::di, io::uo) is det.

check_hr(Name, S, Want, !T, !IO) :-
    ( if lnam_2_5_1_highly_restrictive(S) then Got = yes else Got = no ),
    ( if Got = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred check_start(string::in, char::in, bool::in,
                    tally::in, tally::out, io::di, io::uo) is det.

check_start(Name, C, Want, !T, !IO) :-
    ( if lnam_2_2_1_id_start(C) then Got = yes else Got = no ),
    ( if Got = Want then Ok = yes else Ok = no ),
    check(Name, Ok, !T, !IO).

:- pred test_uniname(tally::in, tally::out, io::di, io::uo) is det.

test_uniname(!T, !IO) :-
    % [LNAM.2.2.1]: the start class is XID_Start plus U+005F, intersected with
    % Identifier_Status=Allowed.
    check_start("[LNAM.2.2.1] `a` is an identifier start", 'a', yes, !T, !IO),
    check_start("[LNAM.2.2.1] `0` is not an identifier start", '0', no,
        !T, !IO),

    ( if lnam_2_2_1_id_continue('0') then B = yes else B = no ),
    check("[LNAM.2.2.1] `0` IS an identifier continue", B, !T, !IO),

    % [LNAM.2.4.1]: NFC, not NFKC, so compatibility characters survive.
    check_nfc("[LNAM.2.4.1] NFC leaves the superscript two alone",
        "x\xB2\", "x\xB2\", !T, !IO),

    check_nfc("[LNAM.2.4.1] NFC leaves the fi ligature alone",
        "\xFB01\", "\xFB01\", !T, !IO),

    % Canonical composition: e + combining acute becomes the precomposed form.
    check_nfc("NFC composes e + U+0301 into U+00E9",
        "e\x301\", "\xE9\", !T, !IO),

    check_nfc("NFC is idempotent on the composed form",
        "\xE9\", "\xE9\", !T, !IO),

    % Hangul composition is algorithmic, in no table; [LNAM.2.5.1] admits
    % Korean identifiers.
    check_nfc("NFC composes Hangul L+V into a syllable",
        "\x1100\\x1161\", "\xAC00\", !T, !IO),

    check_nfc("NFC composes Hangul L+V+T into an LVT syllable",
        "\x1100\\x1161\\x11A8\", "\xAC01\", !T, !IO),

    % [LNAM.2.5.1]: a single script is always allowed.
    check_hr("[LNAM.2.5.1] a Latin name is single-script", "entity_id",
        yes, !T, !IO),

    % `_` and digits are script-neutral (`Zyyy`).
    check_hr("script-neutral characters do not force a mix", "a_1",
        yes, !T, !IO),

    check_hr("an all-neutral name is allowed", "_1", yes, !T, !IO),

    % Mixing outside the three combinations is refused.
    check_hr("[LNAM.2.5.1] Latin + Cyrillic is refused", "pa\x443\pal",
        no, !T, !IO),

    check_hr("[LNAM.2.5.1] Latin + Hangul is admitted", "a\xAC00\",
        yes, !T, !IO).

%-----------------------------------------------------------------------------%
% NFC conformance -- the UCD's own NormalizationTest.txt
%-----------------------------------------------------------------------------%
%
% Format, per [UAX #15] §Conformance: `source; NFC; NFD; NFKC; NFKD`, each a
% space-separated codepoint sequence. The NFC obligations, five a line:
%
%     NFC(c1) == NFC(c2) == NFC(c3) == c2
%     NFC(c4) == NFC(c5) == c4

:- pred test_nfc_conformance(tally::in, tally::out, io::di, io::uo) is det.

test_nfc_conformance(!T, !IO) :-
    io.read_named_file_as_string("NormalizationTest.txt", Res, !IO),
    (
        Res = ok(Text),
        Lines = split_at_char('\n', Text),
        list.foldl3(nfc_line, Lines, 0, Checked, 0, Failed, !IO),
        ( if Failed = 0, Checked > 0 then Ok = yes else Ok = no ),
        check(format("[UAX #15] NormalizationTest: %d assertions, %d failed",
            [i(Checked), i(Failed)]), Ok, !T, !IO)
    ;
        Res = error(_),
        check("NormalizationTest.txt is present and readable", no, !T, !IO)
    ).

:- pred nfc_line(string::in, int::in, int::out, int::in, int::out,
                 io::di, io::uo) is det.

nfc_line(Line, !Checked, !Failed, !IO) :-
    ( if
        not prefix(Line, "#"),
        not prefix(Line, "@"),
        Fields = split_at_char(';', strip(Line)),
        Fields = [F1, F2, F3, F4, F5 | _]
    then
        C1 = cps(F1), C2 = cps(F2), C3 = cps(F3),
        C4 = cps(F4), C5 = cps(F5),
        expect_nfc(C1, C2, !Checked, !Failed, !IO),
        expect_nfc(C2, C2, !Checked, !Failed, !IO),
        expect_nfc(C3, C2, !Checked, !Failed, !IO),
        expect_nfc(C4, C4, !Checked, !Failed, !IO),
        expect_nfc(C5, C4, !Checked, !Failed, !IO)
    else
        true
    ).

:- pred expect_nfc(string::in, string::in, int::in, int::out,
                   int::in, int::out, io::di, io::uo) is det.

expect_nfc(In, Want, !Checked, !Failed, !IO) :-
    !:Checked = !.Checked + 1,
    Got = lnam_2_4_1_nfc(In),
    ( if Got = Want then
        true
    else
        !:Failed = !.Failed + 1,
        % Only the first few.
        ( if !.Failed =< 5 then
            io.format("    NFC(%s) = %s, want %s\n",
                [s(hexes(In)), s(hexes(Got)), s(hexes(Want))], !IO)
        else
            true
        )
    ).

    % A `;`-field of space-separated hex codepoints, as a string.
    %
:- func cps(string) = string.

cps(Field) = from_char_list(list.filter_map(hex_char, words(Field))).

:- func hex_char(string) = char.
:- mode hex_char(in) = out is semidet.

hex_char(W) = C :-
    Trimmed = strip(W),
    Trimmed \= "",
    string.base_string_to_int(16, Trimmed, I),
    char.from_int(I, C).

:- func hexes(string) = string.

hexes(S) = join_list(" ",
    list.map(func(C) = to_upper(int_to_base_string(char.to_int(C), 16)),
        to_char_list(S))).

%-----------------------------------------------------------------------------%
% JSON -- `dsc.json`
%-----------------------------------------------------------------------------%

:- pred test_json(tally::in, tally::out, io::di, io::uo) is det.

test_json(!T, !IO) :-
    check_json("null", "null", j_null, !T, !IO),
    check_json("true", "true", j_bool(yes), !T, !IO),
    check_json("false", "false", j_bool(no), !T, !IO),
    check_json("an integer", "42", j_int(42i64), !T, !IO),
    check_json("a negative integer", "-7", j_int(-7i64), !T, !IO),

    % `j_int` and `j_float` are told apart by spelling: `1.0` and `1e3` are
    % floats.
    check_json("a float", "1.5", j_float(1.5), !T, !IO),
    check_json("`1.0` is a float, not an int", "1.0", j_float(1.0), !T, !IO),
    check_json("an exponent with no point is still a float", "1e3",
        j_float(1000.0), !T, !IO),

    check_json("a string", "\"hi\"", j_string("hi"), !T, !IO),
    check_json("an empty string", "\"\"", j_string(""), !T, !IO),
    check_json("an empty array", "[]", j_array([]), !T, !IO),
    check_json("an empty object", "{}", j_object(empty_object), !T, !IO),
    check_json("a nested array", "[1, [2]]",
        j_array([j_int(1i64), j_array([j_int(2i64)])]), !T, !IO),

    % Whitespace is RFC 8259's four characters, in every position.
    check_json("whitespace everywhere", "\n\t [ 1 , 2 ] \r\n",
        j_array([j_int(1i64), j_int(2i64)]), !T, !IO),

    % A fixture's `rules_ds` is a DS source in one JSON string.
    check_json("the escapes a corpus fixture is made of",
        "\"schema X:\\n    a: String\\n\"",
        j_string("schema X:\n    a: String\n"), !T, !IO),
    check_json("every simple escape",
        "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
        j_string("\"\\/\b\f\n\r\t"), !T, !IO),
    check_json("a `\\u` escape", "\"\\u00b5s\"", j_string("µs"), !T, !IO),

    % A surrogate pair is one character.
    check_json("a surrogate pair is one character", "\"\\uD83D\\uDE00\"",
        j_string("😀"), !T, !IO),

    % [LGRA.5.8.7]: the same key in two objects is not a repeat.
    check_json("the same key in sibling objects",
        "[{\"a\": 1}, {\"a\": 2}]",
        j_array([j_object(object(["a" - j_int(1i64)])),
                 j_object(object(["a" - j_int(2i64)]))]), !T, !IO),

    % Members come back key-ascending, the canonical order.
    check_json("members come back key-ascending",
        "{\"b\": 1, \"a\": 2}",
        j_object(object(["a" - j_int(2i64), "b" - j_int(1i64)])), !T, !IO),

    % ── the refusals ────────────────────────────────────────────────────────

    check_json_error("an empty document", "", !T, !IO),
    check_json_error("whitespace only", "   \n", !T, !IO),
    check_json_error("a bare word", "yes", !T, !IO),
    check_json_error("a truncated literal", "tru", !T, !IO),

    % RFC 8259's `JSON-text` is one value.
    check_json_error("two documents in one file", "{} {}", !T, !IO),
    check_json_error("trailing garbage", "1 x", !T, !IO),

    check_json_error("an unterminated string", "\"abc", !T, !IO),
    check_json_error("an unterminated object", "{\"a\": 1", !T, !IO),
    check_json_error("an unterminated array", "[1, 2", !T, !IO),
    check_json_error("a trailing comma in an object", "{\"a\": 1,}",
        !T, !IO),
    check_json_error("a trailing comma in an array", "[1,]", !T, !IO),
    check_json_error("a missing colon", "{\"a\" 1}", !T, !IO),
    check_json_error("an unquoted key", "{a: 1}", !T, !IO),
    check_json_error("a single-quoted string", "'a'", !T, !IO),
    check_json_error("an unknown escape", "\"\\q\"", !T, !IO),
    check_json_error("a short `\\u` escape", "\"\\u00\"", !T, !IO),
    check_json_error("a lone high surrogate", "\"\\uD83D\"", !T, !IO),

    % [LGRA.5.8.7]: an object that repeats a key is malformed, as
    % libds's `ds_json_parse` refuses it. Keys compare after their escapes are
    % resolved, and an object nested in another is held to it too.
    % @spec [LGRA.5.8.7]
    check_json_error("a repeated key", "{\"a\": 1, \"a\": 2}", !T, !IO),
    check_json_error("a key repeated through an escape",
        "{\"a\": 1, \"\\u0061\": 2}", !T, !IO),
    check_json_error("a repeated key in a nested object",
        "{\"x\": {\"a\": 1, \"a\": 2}}", !T, !IO),
    check_json_error("a lone low surrogate", "\"\\uDE00\"", !T, !IO),

    % RFC 8259 excludes U+0000..U+001F unescaped.
    check_json_error("a raw newline inside a string", "\"a\nb\"", !T, !IO),

    % The error carries the offending offset.
    parse_json("[1, 2, x]", OffsetResult),
    ( if OffsetResult = json_error(_, 7) then OffOk = yes else OffOk = no ),
    check("a parse error carries the offset of the offending character",
        OffOk, !T, !IO),

    % The corpus reader takes Python's three non-finite spellings; strict
    % RFC 8259 does not.
    check_json_error("strict JSON refuses `NaN`", "[NaN]", !T, !IO),
    check_json_error("strict JSON refuses `-Infinity`", "-Infinity", !T, !IO),
    parse_corpus_json("{\"a\": Infinity, \"b\": -Infinity, \"c\": 1}",
        CorpusResult),
    ( if
        CorpusResult = json_ok(j_object(Corpus)),
        members(Corpus) = ["a" - j_float(PosInf), "b" - j_float(NegInf),
            "c" - j_int(1i64)],
        float.is_inf(PosInf), PosInf > 0.0,
        float.is_inf(NegInf), NegInf < 0.0
    then
        CorpusOk = yes
    else
        CorpusOk = no
    ),
    check("the corpus reader takes `Infinity` and `-Infinity` as Floats",
        CorpusOk, !T, !IO),
    parse_corpus_json("[NaN]", NaNResult),
    ( if
        NaNResult = json_ok(j_array([j_float(NaN)])),
        float.is_nan(NaN)
    then
        NaNOk = yes
    else
        NaNOk = no
    ),
    check("the corpus reader takes `NaN` as a Float", NaNOk, !T, !IO),

    % [RCTS.1.2.1]: the corpus reader keeps a repeated name's last binding
    % and reports each repeat, at any depth; a name repeated across
    % different objects is no repeat.
    rcts_1_2_1_parse_corpus_json(
        "{\"a\": 1, \"o\": {\"k\": 1, \"k\": 2, \"k\": 3}, \"a\": 4}",
        RepResult, Repeats),
    ( if
        RepResult = json_ok(j_object(RepObj)),
        members(RepObj) = ["a" - j_int(4i64), "o" - j_object(Inner)],
        members(Inner) = ["k" - j_int(3i64)],
        Repeats = ["k", "k", "a"]
    then
        RepOk = yes
    else
        RepOk = no,
        io.format("    got %s, repeats %s\n",
            [s(string.string(RepResult)), s(string.string(Repeats))], !IO)
    ),
    check("[RCTS.1.2.1] the corpus reader keeps the last binding and reports "
        ++ "each repeat, at any depth", RepOk, !T, !IO),
    rcts_1_2_1_parse_corpus_json(
        "[{\"k\": 1}, {\"k\": 2, \"n\": {\"k\": 3}}]", _, Across),
    check("[RCTS.1.2.1] a name repeated across different objects is no repeat",
        ( if Across = [] then yes else no ), !T, !IO).

:- pred check_json(string::in, string::in, json::in,
                   tally::in, tally::out, io::di, io::uo) is det.

check_json(Name, Text, Want, !T, !IO) :-
    parse_json(Text, Result),
    (
        Result = json_ok(Got),
        ( if Got = Want then
            Ok = yes
        else
            Ok = no,
            io.format("    want %s\n    got  %s\n",
                [s(string.string(Want)), s(string.string(Got))], !IO)
        )
    ;
        Result = json_error(Message, Offset),
        Ok = no,
        io.format("    refused at %d: %s\n", [i(Offset), s(Message)], !IO)
    ),
    check(Name, Ok, !T, !IO).

    % Asserts the refusal, not its wording.
    %
:- pred check_json_error(string::in, string::in,
                         tally::in, tally::out, io::di, io::uo) is det.

check_json_error(Name, Text, !T, !IO) :-
    parse_json(Text, Result),
    (
        Result = json_error(_, _),
        Ok = yes
    ;
        Result = json_ok(Got),
        Ok = no,
        io.format("    accepted, as %s\n", [s(string.string(Got))], !IO)
    ),
    check("refused: " ++ Name, Ok, !T, !IO).

%-----------------------------------------------------------------------------%
:- end_module test_dsc.
%-----------------------------------------------------------------------------%

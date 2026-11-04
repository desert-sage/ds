% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.parse -- tokens to CST, by recursive descent.
%
% The lexer emits a grammar word as `NAME` and the production that needs it
% matches its text in position ([LGRA.2.6], [LLEX.14.2]). `take_name` admits any
% word: refusing a reserved one as a declared name is `dsc.validate.llex_9_5_name`.
%-----------------------------------------------------------------------------%

:- module dsc.parse.
:- interface.

:- import_module dsc.cst.
:- import_module dsc.expr.
:- import_module dsc.token.

:- import_module list.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type parse_error
    --->    pe_expected(string, token)
            % (what was wanted, what was found).

    ;       pe_expected_eof(token)
    ;       pe_unknown_decl(string)
    ;       pe_empty_schema(string)
    ;       pe_empty_lhs(string)
    ;       pe_empty_rhs(string)
    ;       pe_empty_series

    ;       pe_complex_unit(string)
            % `x: complex ohm` ([LUNI.14.9]). The driver reports it as
            % `DS_VALIDATE_COMPLEX_NOT_IN_V1`.

    ;       pe_use_plus_chain
            % `use NAME +cap`.

    ;       pe_use_paren_group
            % `use NAME (cap, ...)`.

    ;       pe_use_empty_block
            % `use NAME:` with no block. A bare `use NAME` has no overrides.

    ;       pe_duplicate_use(pos)
            % A second `use`, carrying the position of the first.

    ;       pe_empty_import_list
            % `from lib import` with nothing after it.

    ;       pe_import_wildcard
            % `from lib import *` ([LIMP.2.4.2]).

    ;       pe_empty_formula
            % One line or three is the validator's
            % `DS_VALIDATE_UNIT_FORMULA_PAIR_ARITY`.

    ;       pe_formula_not_pair
            % `unit formula <name>(...)`: a formula is always a pair ([LUNI.4.5]).

    ;       pe_formula_pair_keyword
            % `unit formula pair <name> ...`.

    ;       pe_formula_modifier_repeated(string)
            % `unit formula f implicit implicit:` ([LUNI.4.5]).

    ;       pe_action_block(string)
            % An indented block under a head that takes none ([LGRA.10.8]).

    ;       pe_test_match_both(string).
            % `emitted S a: 1 t where t.b > 0` ([LGRA.21.1]). The string is the
            % head's keyword.

    %@helper
:- type parse_result
    --->    parse_ok(file)
    ;       parse_error(parse_error, pos).

    %@spec [LGRA.3.1]
    %@spec [LGRA.3.3]
:- pred lgra_3_1_parse(list(positioned)::in, parse_result::out) is det.

    %@helper
:- type expr_result
    --->    ex_ok(lgra_9_3_1_expr, list(positioned))
    ;       ex_error(parse_error, pos).

    % A whole expression, which must consume its entire span: leftover tokens
    % are an error. Exported for the clauses `dsc.cst` carries as spans.
    %
    %@spec [LGRA.9.1]
:- pred lgra_9_1_parse_expr(list(positioned)::in, expr_result::out) is det.

    %@helper
:- func describe_parse_error(parse_error) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module int64.
:- import_module maybe.
:- import_module pair.

%-----------------------------------------------------------------------------%
% Primitives
%-----------------------------------------------------------------------------%

    %@helper
:- func peek(list(positioned)) = token.

peek([]) = dedent.
peek([P | _]) = P ^ tk_tok.

    %@helper
:- func peek_pos(list(positioned), pos) = pos.

peek_pos([], Default) = Default.
peek_pos([P | _], _) = P ^ tk_pos.

    %@helper
:- pred take_name(list(positioned)::in, ident::out, list(positioned)::out)
    is semidet.

take_name([P | Ps], ident(N, P ^ tk_pos), Ps) :-
    P ^ tk_tok = name(N).

    %@helper
:- pred take_kw(string::in, list(positioned)::in, list(positioned)::out)
    is semidet.

take_kw(Kw, [P | Ps], Ps) :-
    P ^ tk_tok = name(Kw).

    %@helper
:- pred take_tok(token::in, list(positioned)::in, list(positioned)::out)
    is semidet.

take_tok(Tok, [P | Ps], Ps) :-
    P ^ tk_tok = Tok.

%-----------------------------------------------------------------------------%
% File
%-----------------------------------------------------------------------------%

lgra_3_1_parse(Toks, Result) :-
    parse_decls(Toks, [], no, DeclsRes),
    (
        DeclsRes = ds_error(Err, P),
        Result = parse_error(Err, P)
    ;
        DeclsRes = ds_ok(Decls, MaybeUse, Rest),
        (
            Rest = [],
            Result = parse_ok(file(MaybeUse, Decls))
        ;
            Rest = [P | _],
            Result = parse_error(pe_expected_eof(P ^ tk_tok), P ^ tk_pos)
        )
    ).

    % A `use` parses anywhere among the declarations: [LGRA.3.2] and [LIMP.2.3.3]
    % are `dsc.validate`'s refusals.
    %
    %@spec [LGRA.3.1]
    %@spec [LGRA.3.3]
:- pred lgra_3_1_parse_use(positioned::in, list(positioned)::in,
    use_result::out) is det.

lgra_3_1_parse_use(UseTok, T1, Result) :-
    Pos = UseTok ^ tk_pos,
    ( if take_name(T1, Base, T2) then
        ( if take_tok(plus, T2, _) then
            Result = use_error(pe_use_plus_chain, peek_pos(T2, Pos))
        else if take_tok(lparen, T2, _) then
            Result = use_error(pe_use_paren_group, peek_pos(T2, Pos))
        else if take_tok(colon, T2, T3) then
            ( if
                take_tok(newline, T3, T4),
                take_tok(indent, T4, T5)
            then
                parse_setting_lines(T5, [], Pos, LinesRes),
                (
                    LinesRes = lines_error(Err, EP),
                    Result = use_error(Err, EP)
                ;
                    LinesRes = lines_ok(Lines, T6),
                    Result = use_ok(use_decl(Base, Lines, Pos), T6)
                )
            else if take_tok(newline, T3, _) then
                Result = use_error(pe_use_empty_block, peek_pos(T3, Pos))
            else
                Result = use_error(pe_expected("the end of the `use` line",
                    peek(T3)), peek_pos(T3, Pos))
            )
        else
            use_line_end(use_decl(Base, [], Pos), T2, Pos, Result)
        )
    else
        Result = use_error(pe_expected("a dialect name", peek(T1)),
            peek_pos(T1, Pos))
    ).

    %@helper
:- pred parse_setting_lines(list(positioned)::in, list(setting_line)::in,
    pos::in, lines_result::out) is det.

parse_setting_lines(Toks, Acc, Pos, Result) :-
    ( if take_tok(dedent, Toks, Rest) then
        Result = lines_ok(reverse(Acc), Rest)
    else if Toks = [] then
        Result = lines_ok(reverse(Acc), [])
    else if take_name(Toks, Cap, T1) then
        ( if take_tok(colon, T1, T2) then
            ( if take_bool(T2, Value, T3) then
                ( if take_tok(newline, T3, T4) then
                    parse_setting_lines(T4,
                        [setting_line(Cap, Value) | Acc], Pos, Result)
                else
                    Result = lines_error(pe_expected("the end of the line",
                        peek(T3)), peek_pos(T3, Pos))
                )
            else
                Result = lines_error(pe_expected("`true` or `false`",
                    peek(T2)), peek_pos(T2, Pos))
            )
        else
            Result = lines_error(pe_expected("`:`", peek(T1)),
                peek_pos(T1, Pos))
        )
    else
        Result = lines_error(pe_expected("a capability name", peek(Toks)),
            peek_pos(Toks, Pos))
    ).

    %@helper
:- pred take_bool(list(positioned)::in, bool::out, list(positioned)::out)
    is semidet.

take_bool([P | Ps], Value, Ps) :-
    ( P ^ tk_tok = name("true"), Value = yes
    ; P ^ tk_tok = name("false"), Value = no
    ).

    %@helper
:- type lines_result
    --->    lines_ok(list(setting_line), list(positioned))
    ;       lines_error(parse_error, pos).

    %@helper
:- pred use_line_end(use_decl::in, list(positioned)::in, pos::in,
    use_result::out) is det.

use_line_end(Decl, Toks, Pos, Result) :-
    ( if take_tok(newline, Toks, Rest) then
        Result = use_ok(Decl, Rest)
    else
        Result = use_error(pe_expected("the end of the `use` line", peek(Toks)),
            peek_pos(Toks, Pos))
    ).

    %@helper
:- type use_result
    --->    use_ok(use_decl, list(positioned))
    ;       use_error(parse_error, pos).

    %@helper
:- type decls_result
    --->    ds_ok(list(top_decl), maybe(use_decl), list(positioned))
    ;       ds_error(parse_error, pos).

    %@helper
:- pred parse_decls(list(positioned)::in, list(top_decl)::in,
                    maybe(use_decl)::in, decls_result::out) is det.

parse_decls([], Acc, Use, ds_ok(reverse(Acc), Use, [])).
parse_decls([P | Ps], Acc, Use, Result) :-
    ( if P ^ tk_tok = newline then
        % The newline that ended the previous declaration's last line.
        parse_decls(Ps, Acc, Use, Result)
    else if P ^ tk_tok = dedent then
        Result = ds_ok(reverse(Acc), Use, [P | Ps])
    else if P ^ tk_tok = name("use") then
        lgra_3_1_parse_use(P, Ps, UseRes),
        (
            UseRes = use_error(Err, EP),
            Result = ds_error(Err, EP)
        ;
            UseRes = use_ok(Parsed, Rest),
            (
                Use = yes(First),
                Result = ds_error(pe_duplicate_use(First ^ u_pos), P ^ tk_pos)
            ;
                Use = no,
                parse_decls(Rest, Acc, yes(Parsed), Result)
            )
        )
    else if P ^ tk_tok = name(Kw), top_keyword(Kw) then
        parse_top_decl(Kw, P ^ tk_pos, [P | Ps], DeclRes),
        (
            DeclRes = td_error(Err, EP),
            Result = ds_error(Err, EP)
        ;
            DeclRes = td_ok(Decl, Rest),
            parse_decls(Rest, [Decl | Acc], Use, Result)
        )
    else if P ^ tk_tok = name(Other) then
        Result = ds_error(pe_unknown_decl(Other), P ^ tk_pos)
    else
        Result = ds_ok(reverse(Acc), Use, [P | Ps])
    ).

    %@helper
:- pred top_keyword(string::in) is semidet.

top_keyword("schema").
top_keyword("rule").
top_keyword("const").
top_keyword("series").
top_keyword("service").
top_keyword("unit").
top_keyword("opaque").
top_keyword("test").
top_keyword("initial").
top_keyword("import").
top_keyword("from").

    %@helper
:- type decl_result
    --->    td_ok(top_decl, list(positioned))
    ;       td_error(parse_error, pos).

    %@helper
:- pred parse_top_decl(string::in, pos::in, list(positioned)::in,
                       decl_result::out) is det.

parse_top_decl(Kw, Pos, Toks, Result) :-
    ( if Kw = "schema" then
        lgra_5_1_parse_schema(Toks, Result)
    else if Kw = "rule" then
        lgra_6_1_parse_rule(Toks, Result)
    else if Kw = "const" then
        lgra_4_1_parse_const(Toks, Result)
    else if Kw = "series" then
        lgra_7_1_parse_series(Toks, Result)
    else if Kw = "service" then
        parse_service(Toks, Result)
    else if Kw = "opaque" then
        lopq_2_1_parse_opaque(Toks, Result)
    else if ( Kw = "import" ; Kw = "from" ) then
        limp_2_1_1_parse_import(Toks, Result)
    else if Kw = "unit" then
        luni_4_parse_unit(Toks, Result)
    else if Kw = "initial" then
        lgra_24_1_parse_initial(Toks, Result)
    else
        ltsl_2_1_parse_test(Toks, Result)
    ).

%-----------------------------------------------------------------------------%
% Tests -- [LTSL], see `dsc.cst`
%-----------------------------------------------------------------------------%

    %@helper
:- type tp(T)
    --->    tp_ok(T, list(positioned))
    ;       tp_error(parse_error, pos).

    %@spec [LTSL.2.1]
    %@spec [LTSL.2.3]
:- pred ltsl_2_1_parse_test(list(positioned)::in, decl_result::out) is det.

ltsl_2_1_parse_test(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("test", Toks, T1),
        take_string(T1, Name, T2),
        block_open(T2, T3)
    then
        test_block(ltsl_2_3_section, T3, [], SecRes),
        (
            SecRes = tp_error(Err, EP),
            Result = td_error(Err, EP)
        ;
            SecRes = tp_ok(Sections, T4),
            ( if Sections = [] then
                Result = td_error(pe_expected("a test section", peek(T3)),
                    peek_pos(T3, Pos))
            else
                Result = td_ok(td_test(ltsl_2_1_test_decl(Name, Sections,
                    Pos)), T4)
            )
        )
    else
        Result = td_error(pe_expected("`test \"<name>\":` and an indented "
            ++ "block", peek(Toks)), Pos)
    ).

    %@spec [LGRA.24.1]
:- pred lgra_24_1_parse_initial(list(positioned)::in, decl_result::out) is det.

lgra_24_1_parse_initial(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("initial", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_5_2_initial_item, T2, [], R),
        (
            R = tp_error(Err, EP),
            Result = td_error(Err, EP)
        ;
            R = tp_ok(Items, T3),
            ( if Items = [] then
                Result = td_error(pe_expected("a fact or a cache seed",
                    peek(T2)), peek_pos(T2, Pos))
            else
                Result = td_ok(td_initial(lgra_24_1_initial_block(Items, Pos)),
                    T3)
            )
        )
    else
        Result = td_error(pe_expected("`initial:` and an indented block",
            peek(Toks)), Pos)
    ).

    % The items of an indented block whose INDENT is consumed, to its DEDENT.
    %
    %@helper
:- pred test_block(pred(list(positioned), tp(T)), list(positioned), list(T),
                   tp(list(T))).
    %@helper
:- mode test_block(pred(in, out) is det, in, in, out) is det.

test_block(Item, Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, T1) then
        test_block(Item, T1, Acc, Result)
    else if take_tok(dedent, Toks, T1) then
        Result = tp_ok(list.reverse(Acc), T1)
    else if Toks = [] then
        Result = tp_ok(list.reverse(Acc), [])
    else
        Item(Toks, ItemRes),
        (
            ItemRes = tp_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            ItemRes = tp_ok(X, T1),
            test_block(Item, T1, [X | Acc], Result)
        )
    ).

    %@helper
:- pred block_open(list(positioned)::in, list(positioned)::out) is semidet.

block_open(Toks, Rest) :-
    take_tok(colon, Toks, T1),
    take_tok(newline, T1, T2),
    take_tok(indent, T2, Rest).

    %@helper
:- pred take_string(list(positioned)::in, lgra_9_3_1_expr::out,
                    list(positioned)::out) is semidet.

take_string([P | Ps], ex_string(S, P ^ tk_pos), Ps) :-
    string_token(P ^ tk_tok, S).

    %@spec [LTSL.2.3]
    %@spec [LTSL.3.5]
:- pred ltsl_2_3_section(list(positioned)::in, tp(ltsl_2_3_section)::out)
    is det.

ltsl_2_3_section(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("until", Toks, T1) then
        ( if lgra_9_6_1_postfix(T1, ex_ok(When, T2)), end_of_clause(T2, T3)
        then
            Result = tp_ok(ts_until(When, P), T3)
        else
            Result = tp_error(pe_expected("a duration or a `calendar.time` "
                ++ "call after `until`", peek(T1)), peek_pos(T1, P))
        )
    else if take_kw("initial", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_5_2_initial_item, T2, [], R),
        Result = map_tp((func(Items) = ts_initial(Items, P)), R)
    else if take_kw("inputs", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_3_3_at_block, T2, [], R),
        Result = map_tp((func(Blocks) = ts_inputs(Blocks, P)), R)
    else if take_kw("responses", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_7_2_stub, T2, [], R),
        Result = map_tp((func(Stubs) = ts_responses(Stubs, P)), R)
    else if take_kw("produces", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_8_2_assertion, T2, [], R),
        Result = map_tp((func(As) = ts_produces(As, P)), R)
    else
        Result = tp_error(pe_expected("a test section -- `initial:`, "
            ++ "`inputs:`, `responses:`, `produces:` or `until`", peek(Toks)),
            P)
    ).

    %@helper
:- func map_tp(func(T) = U, tp(T)) = tp(U).

map_tp(F, tp_ok(X, Rest)) = tp_ok(F(X), Rest).
map_tp(_, tp_error(E, P)) = tp_error(E, P).

    %@spec [LTSL.4.1]
:- pred ltsl_4_1_fact(list(positioned)::in, tp(ltsl_4_1_fact)::out) is det.

ltsl_4_1_fact(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if lgra_8_1_take_type_ref(Toks, Schema, T1) then
        lgra_10_3_1_parse_args(T1, [], ArgRes),
        (
            ArgRes = args2_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            ArgRes = args2_ok(Args, T2),
            ( if end_of_clause(T2, T3) then
                Result = tp_ok(ltsl_4_1_fact(Schema, Args, P), T3)
            else
                Result = tp_error(pe_expected("the end of the fact",
                    peek(T2)), peek_pos(T2, P))
            )
        )
    else
        Result = tp_error(pe_expected("a schema name", peek(Toks)), P)
    ).

    % `cache` is the keyword only where a string or a `:` follows it, so a schema
    % named `cache` still constructs.
    %
    %@spec [LTSL.5.2]
    %@spec [LTSL.5.3]
:- pred ltsl_5_2_initial_item(list(positioned)::in,
                              tp(ltsl_5_2_initial_item)::out) is det.

ltsl_5_2_initial_item(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("cache", Toks, T1), block_open(T1, T2) then
        test_block(ltsl_5_2_seed, T2, [], R),
        Result = map_tp((func(Seeds) = ti_cache_block(Seeds, P)), R)
    else if take_kw("cache", Toks, T1), take_string(T1, _, _) then
        ltsl_5_2_seed(T1, R),
        Result = map_tp(
            (func(Seed) = ti_cache(Seed ^ sd_key, Seed ^ sd_value, P)), R)
    else
        ltsl_4_1_fact(Toks, R),
        Result = map_tp((func(F) = ti_fact(F)), R)
    ).

    %@spec [LTSL.5.2]
:- pred ltsl_5_2_seed(list(positioned)::in, tp(ltsl_5_2_seed)::out) is det.

ltsl_5_2_seed(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if take_string(Toks, Key, T1), take_tok(colon, T1, T2) then
        lgra_9_3_1_or(T2, ValueRes),
        (
            ValueRes = ex_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            ValueRes = ex_ok(Value, T3),
            ( if end_of_clause(T3, T4) then
                Result = tp_ok(ltsl_5_2_seed(Key, Value, P), T4)
            else
                Result = tp_error(pe_expected("the end of the cache seed",
                    peek(T3)), peek_pos(T3, P))
            )
        )
    else
        Result = tp_error(pe_expected("`\"<key>\": <value>`", peek(Toks)), P)
    ).

    %@spec [LTSL.3.3]
    %@spec [LTSL.6.1]
:- pred ltsl_3_3_at_block(list(positioned)::in, tp(ltsl_3_3_at_block)::out)
    is det.

ltsl_3_3_at_block(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("at", Toks, T1),
        lgra_9_6_1_postfix(T1, ex_ok(When, T2)),
        block_open(T2, T3)
    then
        test_block(ltsl_4_1_fact, T3, [], R),
        Result = map_tp((func(Facts) = ltsl_3_3_at_block(When, Facts, P)), R)
    else
        Result = tp_error(pe_expected("`at <duration>:` or `at "
            ++ "calendar.time(...):` and an indented block of facts",
            peek(Toks)), P)
    ).

    %@spec [LTSL.7.2]
    %@spec [LTSL.7.4]
:- pred ltsl_7_2_stub(list(positioned)::in, tp(ltsl_7_2_stub)::out) is det.

ltsl_7_2_stub(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("for", Toks, T1),
        take_kw("call", T1, T2),
        lgra_10_1_take_service_ref(T2, Service, T3)
    then
        take_kwargs(T3, [], KwRes),
        (
            KwRes = tp_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            KwRes = tp_ok(Args, T4),
            ( if take_kw("as", T4, T5), take_string(T5, C, T6) then
                Corr = yes(C),
                T7 = T6
            else
                Corr = no,
                T7 = T4
            ),
            ( if
                take_kw("after", T7, T8),
                lgra_9_7_1_primary(T8, ex_ok(D, T9))
            then
                After = yes(D),
                T10 = T9
            else
                After = no,
                T10 = T7
            ),
            ( if block_open(T10, T11) then
                test_block(ltsl_7_3_reply, T11, [], R),
                Result = map_tp((func(Replies) = ltsl_7_2_stub(Service, Args,
                    Corr, After, Replies, P)), R)
            else
                Result = tp_error(pe_expected("`:` and an indented block of "
                    ++ "replies", peek(T10)), peek_pos(T10, P))
            )
        )
    else
        Result = tp_error(pe_expected("`for call <service>`", peek(Toks)), P)
    ).

    %@spec [LTSL.7.3]
    %@spec [LTSL.7.5]
:- pred ltsl_7_3_reply(list(positioned)::in, tp(ltsl_7_3_reply)::out) is det.

ltsl_7_3_reply(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("no", Toks, T1),
        take_kw("response", T1, T2),
        end_of_clause(T2, T3)
    then
        Result = tp_ok(tr_no_response(P), T3)
    else
        ltsl_4_1_fact(Toks, R),
        Result = map_tp((func(F) = tr_fact(F)), R)
    ).

    % A matching position's kwargs ([LTSL.4.2]): a bare name is the next word of
    % the line, never a flag.
    %
    %@helper
:- pred take_kwargs(list(positioned)::in, list(lgra_10_3_1_action_arg)::in,
                    tp(list(lgra_10_3_1_action_arg))::out) is det.

take_kwargs(Toks, Acc, Result) :-
    ( if take_name(Toks, N, T1), take_tok(colon, T1, T2) then
        lgra_9_3_1_or(T2, ValueRes),
        (
            ValueRes = ex_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            ValueRes = ex_ok(E, T3),
            take_kwargs(T3, [aa_kwarg(N, E, N ^ id_pos) | Acc], Result)
        )
    else
        Result = tp_ok(list.reverse(Acc), Toks)
    ).

    %@spec [LTSL.8.2]
    %@spec [LTSL.8.3]
:- pred ltsl_8_2_assertion(list(positioned)::in, tp(ltsl_8_2_assertion)::out)
    is det.

ltsl_8_2_assertion(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("never", Toks, T1) then
        Never = yes,
        T2 = T1
    else
        Never = no,
        T2 = Toks
    ),
    ltsl_8_2_head(T2, HeadRes),
    (
        HeadRes = tp_error(Err, EP),
        Result = tp_error(Err, EP)
    ;
        HeadRes = tp_ok(Head, T3),
        ( if end_of_clause(T3, T4) then
            Result = tp_ok(ltsl_8_2_assertion(Never, Head, P), T4)
        else
            Result = tp_error(pe_expected("the end of the assertion",
                peek(T3)), peek_pos(T3, P))
        )
    ).

    %@spec [LTSL.8.2]
    %@spec [LTSL.8.4]
:- pred ltsl_8_2_head(list(positioned)::in, tp(ltsl_8_2_head)::out) is det.

ltsl_8_2_head(Toks, Result) :-
    P = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("activated", Toks, T1), take_name(T1, Rule, T2) then
        Result = tp_ok(th_activated(Rule), T2)
    else if take_kw("recorded", Toks, T1), take_name(T1, Kind, T2) then
        Result = tp_ok(th_recorded(Kind), T2)
    else if
        take_kw("emitted", Toks, T1),
        lgra_8_1_take_type_ref(T1, Schema, T2)
    then
        matched_head(T2, "emitted",
            (func(A, W) = th_emitted(Schema, A, W)), Result)
    else if
        take_kw("published", Toks, T1),
        lgra_8_1_take_type_ref(T1, Schema, T2)
    then
        matched_head(T2, "published",
            (func(A, W) = th_published(Schema, A, W)), Result)
    else if
        take_kw("retracted", Toks, T1),
        lgra_8_1_take_type_ref(T1, Schema, T2)
    then
        lgra_10_3_1_parse_args(T2, [], ArgRes),
        (
            ArgRes = args2_error(Err, EP),
            Result = tp_error(Err, EP)
        ;
            ArgRes = args2_ok(Args, T3),
            Result = tp_ok(th_retracted(Schema, Args), T3)
        )
    else if take_kw("called", Toks, T1), lgra_10_1_take_service_ref(T1, S, T2)
    then
        ( if take_kw("as", T2, T3), take_string(T3, C, T4) then
            Result = tp_ok(th_called(S, yes(C)), T4)
        else
            Result = tp_ok(th_called(S, no), T2)
        )
    else if take_kw("cache_deleted", Toks, T1), take_string(T1, Key, T2) then
        Result = tp_ok(th_cache_deleted(Key), T2)
    else if take_kw("cached", Toks, T1), take_string(T1, Key, T2) then
        ( if take_tok(colon, T2, T3) then
            lgra_9_3_1_or(T3, ValueRes),
            (
                ValueRes = ex_error(Err, EP),
                Result = tp_error(Err, EP)
            ;
                ValueRes = ex_ok(V, T4),
                Result = tp_ok(th_cached(Key, yes(V)), T4)
            )
        else
            Result = tp_ok(th_cached(Key, no), T2)
        )
    else if take_kw("logged", Toks, T1), take_name(T1, LevelId, T2) then
        ( if lgra_10_1_1_log_level_of(LevelId ^ id_name, Known) then
            Level = Known
        else
            Level = ll_unknown(LevelId ^ id_name)
        ),
        ( if take_string(T2, Sub, T3) then
            Result = tp_ok(th_logged(Level, yes(Sub)), T3)
        else
            Result = tp_ok(th_logged(Level, no), T2)
        )
    else if take_kw("wm", Toks, T1) then
        ( if take_kw("empty", T1, T2) then
            Result = tp_ok(th_wm_empty, T2)
        else if
            take_kw("count", T1, T2),
            lgra_8_1_take_type_ref(T2, Schema, T3),
            take_tok(eq, T3, T4),
            lgra_9_7_1_primary(T4, ex_ok(N, T5))
        then
            Result = tp_ok(th_wm_count(Schema, N), T5)
        else if
            take_kw("has", T1, T2),
            lgra_8_1_take_type_ref(T2, Schema, T3)
        then
            take_kwargs(T3, [], KwRes),
            Result = map_tp((func(A) = th_wm_has(Schema, A)), KwRes)
        else
            Result = tp_error(pe_expected("`has <Schema>`, `count <Schema> "
                ++ "== <n>` or `empty` after `wm`", peek(T1)),
                peek_pos(T1, P))
        )
    else
        Result = tp_error(pe_expected("an assertion -- `activated`, "
            ++ "`emitted`, `published`, `retracted`, `recorded`, `called`, "
            ++ "`cached`, `cache_deleted`, `logged` or `wm`", peek(Toks)), P)
    ).

    % `emitted` / `published`'s tail: kwargs or `<binding> where <predicate>`,
    % never both. `Head` is the keyword, for the refusal's message.
    %
    %@helper
:- pred matched_head(list(positioned), string,
                     func(list(lgra_10_3_1_action_arg), maybe(ltsl_8_4_where))
                        = ltsl_8_2_head,
                     tp(ltsl_8_2_head)).
    %@helper
:- mode matched_head(in, in, func(in, in) = out is det, out) is det.

matched_head(Toks, Head, Make, Result) :-
    take_kwargs(Toks, [], KwRes),
    (
        KwRes = tp_error(Err, EP),
        Result = tp_error(Err, EP)
    ;
        KwRes = tp_ok(Args, T1),
        ( if take_name(T1, Binding, T2), take_kw("where", T2, T3) then
            (
                Args = [_ | _],
                Result = tp_error(pe_test_match_both(Head), Binding ^ id_pos)
            ;
                Args = [],
                take_where_span(T3, 0, [], Span, T4),
                lgra_9_1_parse_expr(Span, PredRes),
                (
                    PredRes = ex_error(Err, EP),
                    Result = tp_error(Err, EP)
                ;
                    PredRes = ex_ok(Pred, _),
                    Result = tp_ok(Make([],
                        yes(ltsl_8_4_where(Binding, Pred))), T4)
                )
            )
        else
            Result = tp_ok(Make(Args, no), T1)
        )
    ).

%-----------------------------------------------------------------------------%
% Units -- [LUNI.4]
%-----------------------------------------------------------------------------%

    % A form word is a keyword only when no `:` follows it: `unit dimension:
    % length` is a unit named `dimension`.
    %
    %@spec [LUNI.4]
    %@spec [LUNI.4.4]
:- pred luni_4_parse_unit(list(positioned)::in, decl_result::out) is det.

luni_4_parse_unit(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("unit", Toks, T1) then
        ( if unit_form_word(T1, Word, T2) then
            ( if Word = "dimension" then
                luni_4_1_parse_dimension(T2, Pos, Result)
            else if Word = "scalar" then
                luni_4_2_parse_scalar(T2, Pos, Result)
            else if Word = "formula" then
                luni_4_5_parse_formula(T2, Pos, Result)
            else
                luni_4_6_parse_fx_pair(T2, Pos, Result)
            )
        else
            luni_4_3_parse_symbol(T1, Pos, Result)
        )
    else
        Result = td_error(pe_expected("`unit`", peek(Toks)), Pos)
    ).

    %@helper
:- pred unit_form_word(list(positioned)::in, string::out,
                       list(positioned)::out) is semidet.

unit_form_word(Toks, Word, Rest) :-
    take_name(Toks, Id, Rest),
    Word = Id ^ id_name,
    luni_4_4_form_keyword(Word),
    peek(Rest) \= colon.

    %@spec [LUNI.4.4]
:- pred luni_4_4_form_keyword(string::in) is semidet.

luni_4_4_form_keyword("dimension").
luni_4_4_form_keyword("scalar").
luni_4_4_form_keyword("formula").
luni_4_4_form_keyword("fx_pair").

    % The base is taken as a type: `base °C` is a `type_sym` ([LUNI.3.2]).
    %
    %@spec [LUNI.4.1]
:- pred luni_4_1_parse_dimension(list(positioned)::in, pos::in,
                                  decl_result::out) is det.

luni_4_1_parse_dimension(Toks, Pos, Result) :-
    ( if
        take_name(Toks, Name, T1),
        take_kw("storage", T1, T2),
        take_name(T2, Storage, T3),
        take_kw("base", T3, T4),
        llex_10_8_3_take_type(T4, Base, T5),
        take_tok(newline, T5, T6)
    then
        Result = td_ok(td_unit(ud_dimension(Name, Storage, Base, Pos)), T6)
    else
        Result = td_error(pe_expected("`<name> storage <type> base <symbol>` "
            ++ "after `unit dimension`", peek(Toks)), peek_pos(Toks, Pos))
    ).

    %@spec [LUNI.4.2]
:- pred luni_4_2_parse_scalar(list(positioned)::in, pos::in,
                               decl_result::out) is det.

luni_4_2_parse_scalar(Toks, Pos, Result) :-
    ( if
        take_name(Toks, Name, T1),
        take_kw("storage", T1, T2),
        take_name(T2, Storage, T3)
    then
        luni_4_3_take_label(T3, Label, T4),
        ( if take_tok(newline, T4, T5) then
            Result = td_ok(td_unit(ud_scalar(Name, Storage, Label, Pos)), T5)
        else
            Result = td_error(pe_expected("end of line", peek(T4)),
                peek_pos(T4, Pos))
        )
    else
        Result = td_error(pe_expected("`<name> storage <type>` after "
            ++ "`unit scalar`", peek(Toks)), peek_pos(Toks, Pos))
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_parse_symbol(list(positioned)::in, pos::in,
                               decl_result::out) is det.

luni_4_3_parse_symbol(Toks, Pos, Result) :-
    ( if
        llex_10_8_3_take_type(Toks, Symbol, T1),
        take_tok(colon, T1, T2),
        take_name(T2, Dim, T3)
    then
        ( if take_tok(colon, T3, T4) then
            luni_4_3_parse_tier2(T4, Symbol, Dim, Pos, Result)
        else
            luni_4_3_parse_inline(T3, Symbol, Dim, Pos, Result)
        )
    else
        Result = td_error(pe_expected("a unit symbol, `:` and a dimension "
            ++ "name", peek(Toks)), peek_pos(Toks, Pos))
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_parse_inline(list(positioned)::in, ident::in, ident::in,
                               pos::in, decl_result::out) is det.

luni_4_3_parse_inline(Toks, Symbol, Dim, Pos, Result) :-
    ( if take_tok(assign, Toks, T1) then
        luni_4_3_take_affine_span(T1, 0, [], Span, T2),
        ( if Span = [] then
            Result = td_error(pe_expected("a conversion expression after `=`",
                peek(T1)), peek_pos(T1, Pos))
        else
            lgra_9_1_parse_expr(Span, ExprRes),
            (
                ExprRes = ex_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                ExprRes = ex_ok(E, _),
                luni_4_3_finish_inline(T2, Symbol, Dim, ub_affine(E), Pos,
                    Result)
            )
        )
    else
        luni_4_3_finish_inline(Toks, Symbol, Dim, ub_base, Pos, Result)
    ).

    %@helper
:- pred luni_4_3_finish_inline(list(positioned)::in, ident::in, ident::in,
                                luni_4_3_unit_body::in, pos::in,
                                decl_result::out) is det.

luni_4_3_finish_inline(Toks, Symbol, Dim, Body, Pos, Result) :-
    luni_4_3_take_label(Toks, Label, T1),
    luni_4_3_take_aliases(T1, Aliases, T2),
    ( if take_tok(newline, T2, T3) then
        Result = td_ok(td_unit(
            ud_symbol(Symbol, Dim, Body, Label, Aliases, Pos)), T3)
    else
        Result = td_error(pe_expected("`label`, `alias` or end of line",
            peek(T2)), peek_pos(T2, Pos))
    ).

    % The span stops at `label` followed by a string or `alias` followed by a
    % symbol, or at the newline. Two adjacent atoms are no expression, so neither
    % pair occurs inside the body.
    %
    %@spec [LUNI.4.3]
:- pred luni_4_3_take_affine_span(list(positioned)::in, int::in,
                                   list(positioned)::in, list(positioned)::out,
                                   list(positioned)::out) is det.

luni_4_3_take_affine_span([], _, Acc, reverse(Acc), []).
luni_4_3_take_affine_span([P | Ps], Depth, Acc, Span, Rest) :-
    Tok = P ^ tk_tok,
    ( if Tok = newline then
        Span = reverse(Acc),
        Rest = [P | Ps]
    else if Depth = 0, unit_tail_marker([P | Ps]) then
        Span = reverse(Acc),
        Rest = [P | Ps]
    else if llex_7_5_3_bracket_open(Tok, _) then
        luni_4_3_take_affine_span(Ps, Depth + 1, [P | Acc], Span, Rest)
    else if llex_7_5_3_bracket_close(Tok) then
        ( if Depth =< 0 then
            Span = reverse(Acc),
            Rest = [P | Ps]
        else
            luni_4_3_take_affine_span(Ps, Depth - 1, [P | Acc], Span, Rest)
        )
    else
        luni_4_3_take_affine_span(Ps, Depth, [P | Acc], Span, Rest)
    ).

    %@helper
:- pred unit_tail_marker(list(positioned)::in) is semidet.

unit_tail_marker([P, Q | _]) :-
    P ^ tk_tok = name(Word),
    (
        Word = "label",
        string_token(Q ^ tk_tok, _)
    ;
        Word = "alias",
        ( Q ^ tk_tok = name(_)
        ; Q ^ tk_tok = type_sym(_)
        )
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_take_label(list(positioned)::in, maybe(string)::out,
                             list(positioned)::out) is det.

luni_4_3_take_label(Toks, Label, Rest) :-
    ( if
        take_kw("label", Toks, T1),
        T1 = [Q | T2],
        string_token(Q ^ tk_tok, S)
    then
        Label = yes(S),
        Rest = T2
    else
        Label = no,
        Rest = Toks
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_take_aliases(list(positioned)::in, list(ident)::out,
                               list(positioned)::out) is det.

luni_4_3_take_aliases(Toks, Aliases, Rest) :-
    ( if take_kw("alias", Toks, T1), llex_10_8_3_take_type(T1, A, T2) then
        take_alias_tail(T2, [A], Aliases, Rest)
    else
        Aliases = [],
        Rest = Toks
    ).

    %@helper
:- pred take_alias_tail(list(positioned)::in, list(ident)::in,
                        list(ident)::out, list(positioned)::out) is det.

take_alias_tail(Toks, Acc, Aliases, Rest) :-
    ( if take_tok(comma, Toks, T1), llex_10_8_3_take_type(T1, A, T2) then
        take_alias_tail(T2, [A | Acc], Aliases, Rest)
    else
        Aliases = reverse(Acc),
        Rest = Toks
    ).

    %@spec [LUNI.4.3]
:- pred luni_4_3_parse_tier2(list(positioned)::in, ident::in, ident::in,
                              pos::in, decl_result::out) is det.

luni_4_3_parse_tier2(Toks, Symbol, Dim, Pos, Result) :-
    luni_4_3_take_label(Toks, Label, T1),
    ( if take_tok(newline, T1, T2), take_tok(indent, T2, T3) then
        luni_4_3_take_conversion("to_base", T3, ToRes),
        (
            ToRes = ex_error(Err, EP),
            Result = td_error(Err, EP)
        ;
            ToRes = ex_ok(ToBase, T4),
            luni_4_3_take_conversion("from_base", T4, FromRes),
            (
                FromRes = ex_error(Err2, EP2),
                Result = td_error(Err2, EP2)
            ;
                FromRes = ex_ok(FromBase, T5),
                ( if take_tok(dedent, T5, T6) then
                    Body = ub_tier2(
                        luni_4_3_tier2(ToBase, FromBase, Pos)),
                    Result = td_ok(td_unit(ud_symbol(Symbol, Dim, Body,
                        Label, [], Pos)), T6)
                else
                    Result = td_error(pe_expected("the end of the conversion "
                        ++ "block", peek(T5)), peek_pos(T5, Pos))
                )
            )
        )
    else
        Result = td_error(pe_expected("an indented `to_base` / `from_base` "
            ++ "block", peek(T1)), peek_pos(T1, Pos))
    ).

    %@helper
:- pred luni_4_3_take_conversion(string::in, list(positioned)::in,
                                  expr_result::out) is det.

luni_4_3_take_conversion(Word, Toks, Result) :-
    ( if take_kw(Word, Toks, T1), take_tok(colon, T1, T2) then
        take_where_span(T2, 0, [], Span, T3),
        ( if Span = [] then
            Result = ex_error(pe_expected("a conversion expression",
                peek(T2)), peek_pos(T2, pos(1, 0)))
        else
            lgra_9_1_parse_expr(Span, Inner),
            (
                Inner = ex_error(_, _),
                Result = Inner
            ;
                Inner = ex_ok(E, _),
                ( if take_tok(newline, T3, T4) then
                    Result = ex_ok(E, T4)
                else
                    Result = ex_ok(E, T3)
                )
            )
        )
    else
        Result = ex_error(pe_expected("`" ++ Word ++ ":`", peek(Toks)),
            peek_pos(Toks, pos(1, 0)))
    ).

    % The line count is the validator's. `pair` is an ordinary name, so `unit
    % formula pair implicit:` is a formula named `pair`; `pe_formula_pair_keyword`
    % is `pair` followed by a name that is no modifier.
    %
    %@spec [LUNI.4.5]
:- pred luni_4_5_parse_formula(list(positioned)::in, pos::in,
                                decl_result::out) is det.

luni_4_5_parse_formula(Toks, Pos, Result) :-
    ( if take_name(Toks, Name, T2) then
        ( if
            Name ^ id_name = "pair",
            take_name(T2, Next, _),
            not formula_modifier(Next ^ id_name, Pos, _)
        then
            Result = td_error(pe_formula_pair_keyword, peek_pos(Toks, Pos))
        else if take_tok(lparen, T2, _) then
            Result = td_error(pe_formula_not_pair, peek_pos(T2, Pos))
        else
            luni_4_5_take_modifiers(T2, [], Mods, T3),
            ( if luni_4_5_repeated_modifier(Mods, Repeated, RepPos) then
                Result = td_error(pe_formula_modifier_repeated(Repeated),
                    RepPos)
            else if
                take_tok(colon, T3, T4),
                take_tok(newline, T4, T5),
                take_tok(indent, T5, T6)
            then
                luni_4_5_parse_lines(T6, [], LinesRes),
                (
                    LinesRes = fl_error(Err, EP),
                    Result = td_error(Err, EP)
                ;
                    LinesRes = fl_ok(Lines, T7),
                    ( if Lines = [] then
                        Result = td_error(pe_empty_formula, Pos)
                    else if take_tok(dedent, T7, T8) then
                        Result = td_ok(td_unit(
                            ud_formula(Name, Mods, Lines, Pos)), T8)
                    else
                        Result = td_error(pe_expected("a formula line or the "
                            ++ "end of the block", peek(T7)),
                            peek_pos(T7, Pos))
                    )
                )
            else
                Result = td_error(pe_expected("`:` and an indented body after "
                    ++ "the formula's name", peek(T3)),
                    peek_pos(T3, Pos))
            )
        )
    else
        Result = td_error(pe_expected("a formula name", peek(Toks)),
            peek_pos(Toks, Pos))
    ).

    %@spec [LUNI.4.5]
:- pred luni_4_5_repeated_modifier(list(luni_4_5_modifier)::in, string::out,
                                    pos::out) is semidet.

luni_4_5_repeated_modifier([M | Ms], Word, Pos) :-
    ( if
        list.find_first_match(same_formula_modifier(M), Ms, Again)
    then
        formula_modifier_word(Again, Word, Pos)
    else
        luni_4_5_repeated_modifier(Ms, Word, Pos)
    ).

    %@helper
:- pred same_formula_modifier(luni_4_5_modifier::in, luni_4_5_modifier::in)
    is semidet.

same_formula_modifier(A, B) :-
    formula_modifier_word(A, Word, _),
    formula_modifier_word(B, Word, _).

    %@helper
:- pred formula_modifier_word(luni_4_5_modifier::in, string::out, pos::out)
    is det.

formula_modifier_word(fm_inverting(P), "inverting", P).
formula_modifier_word(fm_implicit(P), "implicit", P).

    %@spec [LUNI.4.5]
:- pred luni_4_5_take_modifiers(list(positioned)::in,
                                 list(luni_4_5_modifier)::in,
                                 list(luni_4_5_modifier)::out,
                                 list(positioned)::out) is det.

luni_4_5_take_modifiers(Toks, Acc, Mods, Rest) :-
    ( if Toks = [P | _], take_name(Toks, Id, T1), formula_modifier(Id ^ id_name,
            P ^ tk_pos, M) then
        luni_4_5_take_modifiers(T1, [M | Acc], Mods, Rest)
    else
        Mods = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- pred formula_modifier(string::in, pos::in, luni_4_5_modifier::out)
    is semidet.

formula_modifier("inverting", P, fm_inverting(P)).
formula_modifier("implicit", P, fm_implicit(P)).

    %@helper
:- type flines_result
    --->    fl_ok(list(luni_4_5_formula_line), list(positioned))
    ;       fl_error(parse_error, pos).

    %@helper
:- pred luni_4_5_parse_lines(list(positioned)::in,
                              list(luni_4_5_formula_line)::in,
                              flines_result::out) is det.

luni_4_5_parse_lines(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        luni_4_5_parse_lines(TN, Acc, Result)
    else if
        Toks = [P | _],
        take_name(Toks, Name, T1),
        take_tok(lparen, T1, T2),
        take_name(T2, Param, T3),
        take_tok(colon, T3, T4),
        llex_10_8_3_take_type(T4, ParamType, T5),
        take_tok(rparen, T5, T6),
        take_tok(colon, T6, T7),
        llex_10_8_3_take_type(T7, Return, T8),
        take_tok(assign, T8, T9)
    then
        take_where_span(T9, 0, [], Span, T10),
        ( if Span = [] then
            Result = fl_error(pe_expected("a formula expression after `=`",
                peek(T9)), peek_pos(T9, P ^ tk_pos))
        else
            lgra_9_1_parse_expr(Span, ExprRes),
            (
                ExprRes = ex_error(Err, EP),
                Result = fl_error(Err, EP)
            ;
                ExprRes = ex_ok(E, _),
                ( if take_tok(newline, T10, T11) then T12 = T11 else T12 = T10 ),
                Line = luni_4_5_formula_line(Name, Param, ParamType, Return,
                    E, P ^ tk_pos),
                luni_4_5_parse_lines(T12, [Line | Acc], Result)
            )
        )
    else
        Result = fl_ok(reverse(Acc), Toks)
    ).

    % The selector's restriction is the validator's.
    %
    %@spec [LUNI.4.6]
:- pred luni_4_6_parse_fx_pair(list(positioned)::in, pos::in,
                                decl_result::out) is det.

luni_4_6_parse_fx_pair(Toks, Pos, Result) :-
    ( if
        llex_10_8_3_take_type(Toks, Name, T1),
        take_tok(colon, T1, T2),
        take_name(T2, From, T3),
        take_kw("to", T3, T4),
        take_name(T4, To, T5),
        take_tok(newline, T5, T6),
        take_tok(indent, T6, T7),
        take_kw("via", T7, T8),
        take_name(T8, Via, T9),
        take_kw("where", T9, T10)
    then
        take_where_span(T10, 0, [], Span, T11),
        ( if Span = [] then
            Result = td_error(pe_expected("a rate selector after `where`",
                peek(T10)), peek_pos(T10, Pos))
        else
            lgra_9_1_parse_expr(Span, ExprRes),
            (
                ExprRes = ex_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                ExprRes = ex_ok(Sel, _),
                luni_4_6_parse_field(T11, Name, From, To, Via, Sel, Pos,
                    Result)
            )
        )
    else
        Result = td_error(pe_expected("`<name>: <from> to <to>` and an "
            ++ "indented `via` line", peek(Toks)), peek_pos(Toks, Pos))
    ).

    %@spec [LUNI.4.6]
:- pred luni_4_6_parse_field(list(positioned)::in, ident::in, ident::in,
                              ident::in, ident::in, lgra_9_3_1_expr::in,
                              pos::in, decl_result::out) is det.

luni_4_6_parse_field(Toks, Name, From, To, Via, Sel, Pos, Result) :-
    ( if take_tok(newline, Toks, TN) then
        luni_4_6_parse_field(TN, Name, From, To, Via, Sel, Pos, Result)
    else if
        take_kw("field", Toks, T1),
        take_name(T1, Num, T2),
        take_tok(slash, T2, T3),
        take_name(T3, Den, T4)
    then
        ( if take_tok(newline, T4, T5) then T6 = T5 else T6 = T4 ),
        ( if take_tok(dedent, T6, T7) then
            Result = td_ok(td_unit(ud_fx_pair(Name, From, To, Via, Sel,
                Num, Den, Pos)), T7)
        else
            Result = td_error(pe_expected("the end of the `fx_pair` block",
                peek(T6)), peek_pos(T6, Pos))
        )
    else
        Result = td_error(pe_expected("a `field <num> / <den>` line",
            peek(Toks)), peek_pos(Toks, Pos))
    ).

%-----------------------------------------------------------------------------%
% Imports -- [LIMP.2.1.1]
%-----------------------------------------------------------------------------%

    % Admitted wherever a declaration is: placement is `dsc.validate`'s.
    %
    %@spec [LIMP.2.1.1]
    %@spec [LIMP.2.1.4]
    %@spec [LIMP.2.1.7]
    %@spec [LIMP.2.4.3]
:- pred limp_2_1_1_parse_import(list(positioned)::in, decl_result::out) is det.

limp_2_1_1_parse_import(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("import", Toks, T1) then
        ( if limp_2_1_4_parse_path(T1, Path, T2) then
            limp_2_1_7_parse_alias(T2, Alias, T3),
            ( if take_tok(newline, T3, T4) then
                Result = td_ok(
                    td_import(limp_2_1_1_qualified(Path, Alias, Pos)), T4)
            else
                Result = td_error(pe_expected("end of line", peek(T3)),
                    peek_pos(T3, Pos))
            )
        else
            Result = td_error(pe_expected("a library name", peek(T1)),
                peek_pos(T1, Pos))
        )
    else if take_kw("from", Toks, T1) then
        ( if
            limp_2_1_4_parse_path(T1, Path, T2),
            take_kw("import", T2, T3)
        then
            limp_2_1_1_parse_list(T3, ListRes),
            (
                ListRes = il_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                ListRes = il_ok(Items, T4),
                (
                    Items = [],
                    Result = td_error(pe_empty_import_list, peek_pos(T3, Pos))
                ;
                    Items = [_ | _],
                    ( if take_tok(newline, T4, T5) then
                        Result = td_ok(
                            td_import(limp_2_1_1_selective(Path, Items, Pos)),
                            T5)
                    else
                        Result = td_error(pe_expected("end of line", peek(T4)),
                            peek_pos(T4, Pos))
                    )
                )
            )
        else
            Result = td_error(
                pe_expected("a library name followed by `import`", peek(T1)),
                peek_pos(T1, Pos))
        )
    else
        Result = td_error(pe_expected("`import` or `from`", peek(Toks)), Pos)
    ).

    %@spec [LIMP.2.1.4]
    %@spec [LIMP.2.4.3]
:- pred limp_2_1_4_parse_path(list(positioned)::in, list(ident)::out,
                              list(positioned)::out) is semidet.

limp_2_1_4_parse_path(Toks, [First | Rest], Out) :-
    take_name(Toks, First, T1),
    parse_path_tail(T1, [], Rest, Out).

    %@helper
:- pred parse_path_tail(list(positioned)::in, list(ident)::in, list(ident)::out,
                        list(positioned)::out) is det.

parse_path_tail(Toks, Acc, Segments, Rest) :-
    ( if take_tok(dot, Toks, T1), take_name(T1, N, T2) then
        parse_path_tail(T2, [N | Acc], Segments, Rest)
    else
        Segments = reverse(Acc),
        Rest = Toks
    ).

    %@spec [LIMP.2.1.7]
:- pred limp_2_1_7_parse_alias(list(positioned)::in, maybe(ident)::out,
                               list(positioned)::out) is det.

limp_2_1_7_parse_alias(Toks, Alias, Rest) :-
    ( if take_kw("as", Toks, T1), take_name(T1, N, T2) then
        Alias = yes(N),
        Rest = T2
    else
        Alias = no,
        Rest = Toks
    ).

    %@helper
:- type import_list_result
    --->    il_ok(list(limp_2_1_1_import_item), list(positioned))
    ;       il_error(parse_error, pos).

    %@spec [LIMP.2.1.1]
    %@spec [LIMP.2.2.1]
    %@spec [LIMP.2.2.2]
    %@spec [LIMP.2.4.2]
:- pred limp_2_1_1_parse_list(list(positioned)::in, import_list_result::out)
    is det.

limp_2_1_1_parse_list(Toks, Result) :-
    ( if take_tok(lparen, Toks, T1) then
        parse_import_items(T1, [], Inner),
        (
            Inner = il_error(_, _),
            Result = Inner
        ;
            Inner = il_ok(Items, T2),
            ( if take_tok(rparen, T2, T3) then
                Result = il_ok(Items, T3)
            else
                Result = il_error(pe_expected("`)` or another name", peek(T2)),
                    peek_pos(T2, pos(1, 0)))
            )
        )
    else
        parse_import_items(Toks, [], Result)
    ).

    % A trailing comma ([LIMP.2.2.2]): the next round finds no name and stops.
    %
    %@helper
:- pred parse_import_items(list(positioned)::in,
                           list(limp_2_1_1_import_item)::in,
                           import_list_result::out) is det.

parse_import_items(Toks, Acc, Result) :-
    ( if take_tok(star, Toks, _) then
        Result = il_error(pe_import_wildcard, peek_pos(Toks, pos(1, 0)))
    else if take_name(Toks, Name, T1) then
        limp_2_1_7_parse_alias(T1, Alias, T2),
        Item = limp_2_1_1_import_item(Name, Alias, Name ^ id_pos),
        ( if take_tok(comma, T2, T3) then
            parse_import_items(T3, [Item | Acc], Result)
        else
            Result = il_ok(reverse([Item | Acc]), T2)
        )
    else
        Result = il_ok(reverse(Acc), Toks)
    ).

%-----------------------------------------------------------------------------%
% Opaque types -- [LOPQ.2.1]
%-----------------------------------------------------------------------------%

    % The representation is any name: `dsc.validate` refuses an unsupported one.
    %
    %@spec [LOPQ.2.1]
:- pred lopq_2_1_parse_opaque(list(positioned)::in, decl_result::out) is det.

lopq_2_1_parse_opaque(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("opaque", Toks, T1),
        take_kw("type", T1, T2),
        take_name(T2, Name, T3),
        take_kw("over", T3, T4),
        take_name(T4, Repr, T5)
    then
        ( if end_of_clause(T5, T6) then
            Result = td_ok(td_opaque(lopq_2_1_opaque_decl(Name, Repr, Pos)),
                T6)
        else
            Result = td_error(pe_expected("the end of the `opaque` "
                ++ "declaration", peek(T5)), peek_pos(T5, Pos))
        )
    else
        Result = td_error(pe_expected("`opaque type <Name> over <repr>`",
            peek(Toks)), Pos)
    ).

%-----------------------------------------------------------------------------%
% Services -- [LGRA.23.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.23.1]
:- pred parse_service(list(positioned)::in, decl_result::out) is det.

parse_service(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("service", Toks, T1) then
        take_dotted_path(T1, [], Name, T2),
        ( if
            Name = [_ | _],
            take_tok(colon, T2, T3),
            take_tok(newline, T3, T4),
            take_tok(indent, T4, T5)
        then
            lgra_5_6_parse_doc(T5, Doc, T6),
            parse_service_body(T6, [], BodyRes),
            (
                BodyRes = svbody_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                BodyRes = svbody_ok(Kwargs, Response, Hydration, T7),
                ( if take_tok(dedent, T7, T8) then
                    Result = td_ok(td_service(service_decl(Name, Doc, Kwargs,
                        Response, Hydration, Pos)), T8)
                else
                    Result = td_error(pe_expected("a `kwarg` line, or the "
                        ++ "service's last line, `response T` or "
                        ++ "`no response`", peek(T7)), peek_pos(T7, Pos))
                )
            )
        else
            Result = td_error(pe_expected("a service name and an indented "
                ++ "body", peek(T2)), peek_pos(T2, Pos))
        )
    else
        Result = td_error(pe_expected("`service`", peek(Toks)), Pos)
    ).

    %@helper
:- type svbody_result
    --->    svbody_ok(list(service_kwarg), response_decl,
                      list(hydration_field), list(positioned))
    ;       svbody_error(parse_error, pos).

    % A body with no response line parses: the omission is the validator's
    % ([LGRA.23.2]). The hydration list is always empty.
    %
    %@spec [LGRA.23.1]
    %@helper
:- pred parse_service_body(list(positioned)::in, list(service_kwarg)::in,
                           svbody_result::out) is det.

parse_service_body(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_service_body(TN, Acc, Result)
    else if peek(Toks) = name("kwarg") then
        parse_service_kwarg(Toks, KwRes),
        (
            KwRes = svkw_error(Err, EP),
            Result = svbody_error(Err, EP)
        ;
            KwRes = svkw_ok(K, T1),
            parse_service_body(T1, [K | Acc], Result)
        )
    else if
        take_kw("response", Toks, TR),
        llex_10_8_3_take_type(TR, RName, TR2)
    then
        end_of_line_opt(TR2, T1),
        Result = svbody_ok(reverse(Acc), rd_schema(RName), [], T1)
    else if
        Toks = [P | _],
        take_kw("no", Toks, TN1),
        take_kw("response", TN1, TN2)
    then
        end_of_line_opt(TN2, T1),
        Result = svbody_ok(reverse(Acc), rd_none(P ^ tk_pos), [], T1)
    else
        Result = svbody_ok(reverse(Acc), rd_absent, [], Toks)
    ).

    %@helper
:- pred end_of_line_opt(list(positioned)::in, list(positioned)::out) is det.

end_of_line_opt(Toks, Rest) :-
    ( if take_tok(newline, Toks, R) then Rest = R else Rest = Toks ).

    %@helper
:- type svkw_result
    --->    svkw_ok(service_kwarg, list(positioned))
    ;       svkw_error(parse_error, pos).

    %@helper
:- pred parse_service_kwarg(list(positioned)::in, svkw_result::out) is det.

parse_service_kwarg(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("kwarg", Toks, T1),
        take_name(T1, Name, T2),
        take_tok(colon, T2, T3),
        llex_10_8_3_take_type(T3, Ty, T4)
    then
        take_kwarg_modifiers(T4, [], Mods, T5),
        ( if end_of_clause(T5, T6) then
            Result = svkw_ok(service_kwarg(Name, Ty, Mods, Pos), T6)
        else if take_kw("default", T5, T6) then
            Result = svkw_error(pe_expected("a literal after `default`, "
                ++ "optionally signed (LGRA.23.1)", peek(T6)),
                peek_pos(T6, Pos))
        else
            Result = svkw_error(pe_expected("the end of the `kwarg` line",
                peek(T5)), peek_pos(T5, Pos))
        )
    else
        Result = svkw_error(pe_expected("`kwarg NAME: Type`", peek(Toks)), Pos)
    ).

    %@helper
:- pred take_kwarg_modifiers(list(positioned)::in, list(kwarg_modifier)::in,
                             list(kwarg_modifier)::out,
                             list(positioned)::out) is det.

take_kwarg_modifiers(Toks, Acc, Mods, Rest) :-
    ( if
        Toks = [P | _],
        take_kw("default", Toks, T1),
        lgra_23_1_default_value(T1, E, T2)
    then
        take_kwarg_modifiers(T2, [km_default(E, P ^ tk_pos) | Acc], Mods, Rest)
    else if Toks = [P | _], take_kw("literal", Toks, T1) then
        take_kwarg_modifiers(T1, [km_literal(P ^ tk_pos) | Acc], Mods, Rest)
    else if Toks = [P | _], take_kw("required", Toks, T1) then
        take_kwarg_modifiers(T1, [km_required(P ^ tk_pos) | Acc], Mods, Rest)
    else
        Mods = reverse(Acc),
        Rest = Toks
    ).

    % `'-'? literal`, not a `primary`. Which literals a `-` may precede is
    % `dsc.validate.lgra_23_2_default_type`'s.
    %
    %@spec LGRA.23.1
:- pred lgra_23_1_default_value(list(positioned)::in, lgra_9_3_1_expr::out,
                                list(positioned)::out) is semidet.

lgra_23_1_default_value(Toks, E, Rest) :-
    ( if
        Toks = [Minus, Magnitude | AfterMin],
        Minus ^ tk_tok = minus,
        Magnitude ^ tk_tok = int_min_magnitude
    then
        E = ex_int(int64.min_int64, Minus ^ tk_pos),
        Rest = AfterMin
    else if Toks = [Minus | AfterSign], Minus ^ tk_tok = minus then
        lgra_4_1_literal(AfterSign, Literal, Rest),
        E = ex_unary(uo_neg, Literal, Minus ^ tk_pos)
    else
        lgra_4_1_literal(Toks, E, Rest)
    ).

    % [LGRA.4.1]'s `literal`: a literal token, and `true` / `false`, which
    % arrive as `name` and are recognised by text. Not `null`, which the
    % production does not list.
    %
    %@spec [LGRA.4.1]
:- pred lgra_4_1_literal(list(positioned)::in, lgra_9_3_1_expr::out,
                         list(positioned)::out) is semidet.

lgra_4_1_literal([P | Rest], E, Rest) :-
    Pos = P ^ tk_pos,
    Tok = P ^ tk_tok,
    (
        Tok = int_lit(I),
        E = ex_int(I, Pos)
    ;
        Tok = float_lit(F),
        E = ex_float(F, Pos)
    ;
        Tok = single_str(S),
        E = ex_string(S, Pos)
    ;
        Tok = triple_str(S),
        E = ex_string(S, Pos)
    ;
        Tok = unit_lit(Mag, Suffix),
        E = ex_unit(Mag, Suffix, Pos)
    ;
        Tok = name("true"),
        E = ex_bool(yes, Pos)
    ;
        Tok = name("false"),
        E = ex_bool(no, Pos)
    ).

%-----------------------------------------------------------------------------%
% Constants -- [LGRA.4.1]
%-----------------------------------------------------------------------------%

    % `const N: 1`, with no `=` after the annotation, is the retired spelling.
    %
    %@spec [LGRA.4.1]
    %@spec [LGRA.4.5]
:- pred lgra_4_1_parse_const(list(positioned)::in, decl_result::out) is det.

lgra_4_1_parse_const(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("const", Toks, T1), take_name(T1, Name, T2) then
        ( if take_tok(assign, T2, T3) then
            const_value(T3, no, Name, Pos, Result)
        else if take_tok(colon, T2, T3) then
            ( if
                llex_10_8_3_take_type(T3, Ty, T4),
                annotation_nullable(T4, Null, T5),
                take_tok(assign, T5, T6)
            then
                const_value(T6, yes(lgra_6_7_2_annotation(Ty, Null)), Name,
                    Pos, Result)
            else
                const_legacy(T3, Name, Pos, Result)
            )
        else
            Result = td_error(pe_expected("`=` or a type annotation after the "
                ++ "constant's name", peek(T2)), peek_pos(T2, Pos))
        )
    else
        Result = td_error(pe_expected("a constant name", peek(Toks)), Pos)
    ).

    %@helper
:- pred annotation_nullable(list(positioned)::in, nullability::out,
                            list(positioned)::out) is det.

annotation_nullable(Toks, Null, Rest) :-
    ( if take_tok(question, Toks, T1) then
        Null = nullable,
        Rest = T1
    else
        Null = non_null,
        Rest = Toks
    ).

    %@helper
:- pred const_value(list(positioned)::in, maybe(lgra_6_7_2_annotation)::in,
                    ident::in, pos::in, decl_result::out) is det.

const_value(Toks, Ann, Name, Pos, Result) :-
    take_binding_value(Toks, Pos, ValRes),
    (
        ValRes = val_error(Err, EP),
        Result = td_error(Err, EP)
    ;
        ValRes = val_ok(E, Rest),
        Result = td_ok(td_const(lgra_4_1_const_decl(Name, cf_value(Ann, E),
            Pos)), Rest)
    ).

    %@helper
:- pred const_legacy(list(positioned)::in, ident::in, pos::in,
                     decl_result::out) is det.

const_legacy(Toks, Name, Pos, Result) :-
    take_binding_value(Toks, Pos, ValRes),
    (
        ValRes = val_error(Err, EP),
        Result = td_error(Err, EP)
    ;
        ValRes = val_ok(E, Rest),
        Result = td_ok(td_const(lgra_4_1_const_decl(Name,
            cf_colon_literal(E), Pos)), Rest)
    ).

%-----------------------------------------------------------------------------%
% Series -- [LGRA.7.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.7.1]
    %@spec [LGRA.7.9]
:- pred lgra_7_1_parse_series(list(positioned)::in, decl_result::out) is det.

lgra_7_1_parse_series(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("series", Toks, T1), lgra_7_3_take_slot_ref(T1, Ref, T2) then
        lgra_7_1_take_block_opts(T2, [], Opts, T3),
        ( if
            take_tok(colon, T3, T4),
            take_tok(newline, T4, T5),
            take_tok(indent, T5, T6)
        then
            lgra_5_6_parse_doc(T6, Doc, T7),
            parse_series_lines(T7, [], LineRes),
            (
                LineRes = slines_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                LineRes = slines_ok(Lines, T8),
                ( if Lines = [] then
                    Result = td_error(pe_empty_series, Pos)
                else if take_tok(dedent, T8, T9) then
                    Result = td_ok(td_series(lgra_7_1_series_decl(Ref, Opts,
                        Doc, Lines, Pos)), T9)
                else
                    Result = td_error(pe_expected("an observation line or the "
                        ++ "end of the series block", peek(T8)),
                        peek_pos(T8, Pos))
                )
            )
        else
            Result = td_error(pe_expected("`:` and an indented series body",
                peek(T3)), peek_pos(T3, Pos))
        )
    else
        Result = td_error(pe_expected("a slot reference after `series`",
            peek(Toks)), Pos)
    ).

    %@spec [LGRA.7.3]
:- pred lgra_7_3_take_slot_ref(list(positioned)::in, lgra_7_3_slot_ref::out,
                               list(positioned)::out) is semidet.

lgra_7_3_take_slot_ref(Toks, Ref, Rest) :-
    take_name(Toks, First, T1),
    ( if take_tok(dot, T1, T2), take_name(T2, Second, T3) then
        Ref = lgra_7_3_slot_ref(yes(First), Second),
        Rest = T3
    else
        Ref = lgra_7_3_slot_ref(no, First),
        Rest = T1
    ).

    %@spec [LGRA.7.1]
:- pred lgra_7_1_take_block_opts(list(positioned)::in,
                                 list(lgra_7_1_block_kwarg)::in,
                                 list(lgra_7_1_block_kwarg)::out,
                                 list(positioned)::out) is det.

lgra_7_1_take_block_opts(Toks, Acc, Opts, Rest) :-
    ( if Acc = [], take_tok(lparen, Toks, T1) then
        take_block_kwargs(T1, [], Opts, Rest)
    else
        Opts = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- pred take_block_kwargs(list(positioned)::in,
                          list(lgra_7_1_block_kwarg)::in,
                          list(lgra_7_1_block_kwarg)::out,
                          list(positioned)::out) is det.

take_block_kwargs(Toks, Acc, Opts, Rest) :-
    ( if
        Toks = [P | _],
        take_name(Toks, Kw, T1),
        take_tok(colon, T1, T2),
        block_kwarg_value(Kw ^ id_name, T2, Opt, T3, P ^ tk_pos)
    then
        ( if take_tok(comma, T3, T4) then
            take_block_kwargs(T4, [Opt | Acc], Opts, Rest)
        else if take_tok(rparen, T3, T4) then
            Opts = reverse([Opt | Acc]),
            Rest = T4
        else
            Opts = reverse([Opt | Acc]),
            Rest = T3
        )
    else
        Opts = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- pred block_kwarg_value(string::in, list(positioned)::in,
                          lgra_7_1_block_kwarg::out, list(positioned)::out,
                          pos::in) is semidet.

block_kwarg_value("by", Toks, bk_by(By, Pos), Rest, Pos) :-
    take_name(Toks, N, Rest),
    ( if N ^ id_name = "none" then By = by_none(N ^ id_pos) else By = by_name(N) ).
    % `N < 1` is the validator's.
block_kwarg_value("capacity", Toks, bk_capacity(P, Pos), Rest, Pos) :-
    Toks = [P | Rest],
    P ^ tk_tok = int_lit(_).
block_kwarg_value("nulls", Toks, bk_nulls(N, Pos), Rest, Pos) :-
    take_name(Toks, N, Rest),
    ( N ^ id_name = "skip"
    ; N ^ id_name = "hold"
    ; N ^ id_name = "zero"
    ).

    %@helper
:- type slines_result
    --->    slines_ok(list(lgra_7_1_series_line), list(positioned))
    ;       slines_error(parse_error, pos).

    %@helper
:- pred parse_series_lines(list(positioned)::in,
                           list(lgra_7_1_series_line)::in,
                           slines_result::out) is det.

parse_series_lines(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_series_lines(TN, Acc, Result)
    else if peek(Toks) = name(_) then
        lgra_7_1_parse_series_line(Toks, LineRes),
        (
            LineRes = sline_error(Err, EP),
            Result = slines_error(Err, EP)
        ;
            LineRes = sline_ok(L, T1),
            parse_series_lines(T1, [L | Acc], Result)
        )
    else
        Result = slines_ok(reverse(Acc), Toks)
    ).

    %@helper
:- type sline_result
    --->    sline_ok(lgra_7_1_series_line, list(positioned))
    ;       sline_error(parse_error, pos).

    % An unknown aggregation parses ([LGRA.7.6]) and `dsc.validate` names it.
    %
    %@spec [LGRA.7.1]
    %@spec [LGRA.7.6]
:- pred lgra_7_1_parse_series_line(list(positioned)::in, sline_result::out)
    is det.

lgra_7_1_parse_series_line(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    take_agg_list(Toks, [], Aggs, T1),
    (
        Aggs = [],
        Result = sline_error(pe_expected("an aggregation name", peek(Toks)),
            Pos)
    ;
        Aggs = [_ | _],
        ( if lgra_7_1_take_time_model(T1, Time, T2) then
            lgra_7_1_take_accuracy(T2, Accuracy, T3),
            lgra_7_6a_take_gap(T3, Gap, T4),
            ( if take_kw("as", T4, T5), take_name(T5, As, T6) then
                MaybeAs = yes(As),
                T7 = T6
            else
                MaybeAs = no,
                T7 = T4
            ),
            ( if end_of_clause(T7, T8) then
                Result = sline_ok(lgra_7_1_series_line(Aggs, Time, Accuracy,
                    Gap, MaybeAs, Pos), T8)
            else
                Result = sline_error(pe_expected("the end of the observation "
                    ++ "line", peek(T7)), peek_pos(T7, Pos))
            )
        else
            Result = sline_error(pe_expected("a time model", peek(T1)),
                peek_pos(T1, Pos))
        )
    ).

    %@helper
:- pred take_agg_list(list(positioned)::in, list(ident)::in, list(ident)::out,
                      list(positioned)::out) is det.

take_agg_list(Toks, Acc, Aggs, Rest) :-
    ( if take_name(Toks, N, T1), take_tok(comma, T1, T2) then
        take_agg_list(T2, [N | Acc], Aggs, Rest)
    else if take_name(Toks, N, T1), not time_model_keyword(N ^ id_name) then
        Aggs = reverse([N | Acc]),
        Rest = T1
    else
        Aggs = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- pred time_model_keyword(string::in) is semidet.

time_model_keyword("all_time").
time_model_keyword("sliding").
time_model_keyword("tumbling").
time_model_keyword("sample").

    %@spec [LGRA.7.1]
:- pred lgra_7_1_take_time_model(list(positioned)::in,
                                 lgra_7_1_time_model::out,
                                 list(positioned)::out) is semidet.

lgra_7_1_take_time_model(Toks, Model, Rest) :-
    Toks = [P | _],
    Pos = P ^ tk_pos,
    ( if take_kw("all_time", Toks, T1) then
        Model = tm_all_time(Pos),
        Rest = T1
    else if take_kw("sliding", Toks, T1) then
        take_model_arg(T1, E, Rest),
        Model = tm_sliding(E, Pos)
    else if take_kw("tumbling", Toks, T1) then
        take_model_arg(T1, E, Rest),
        Model = tm_tumbling(E, Pos)
    else
        take_kw("sample", Toks, T1),
        take_model_arg(T1, E, Rest),
        Model = tm_sample(E, Pos)
    ).

    % One primary: what follows on the line starts with a bare name.
    %
    %@helper
:- pred take_model_arg(list(positioned)::in, lgra_9_3_1_expr::out,
                       list(positioned)::out) is semidet.

take_model_arg(Toks, E, Rest) :-
    lgra_9_7_1_primary(Toks, ex_ok(E, Rest)).

    %@spec [LGRA.7.1]
:- pred lgra_7_1_take_accuracy(list(positioned)::in, maybe(lgra_7_1_accuracy)::out,
                      list(positioned)::out) is det.

lgra_7_1_take_accuracy(Toks, Accuracy, Rest) :-
    ( if Toks = [P | _] then
        Pos = P ^ tk_pos,
        ( if take_kw("exact", Toks, T1) then
            Accuracy = yes(ac_exact(Pos)),
            Rest = T1
        else if take_kw("bound", Toks, T1), take_kw("deterministic", T1, T2)
        then
            Accuracy = yes(ac_bound_deterministic(Pos)),
            Rest = T2
        else if
            take_name(Toks, Kw, T1),
            accuracy_keyword(Kw ^ id_name),
            lgra_9_7_1_primary(T1, ex_ok(E, T2))
        then
            ( if Kw ^ id_name = "tolerance" then
                Accuracy = yes(ac_tolerance(E, Pos))
            else if Kw ^ id_name = "confidence" then
                Accuracy = yes(ac_confidence(E, Pos))
            else
                Accuracy = yes(ac_delta(E, Pos))
            ),
            Rest = T2
        else
            Accuracy = no,
            Rest = Toks
        )
    else
        Accuracy = no,
        Rest = Toks
    ).

    %@helper
:- pred accuracy_keyword(string::in) is semidet.

accuracy_keyword("tolerance").
accuracy_keyword("confidence").
accuracy_keyword("delta").

    %@spec [LGRA.7.6a]
:- pred lgra_7_6a_take_gap(list(positioned)::in,
                           maybe(lgra_7_6a_gap_policy)::out,
                           list(positioned)::out) is det.

lgra_7_6a_take_gap(Toks, Gap, Rest) :-
    ( if
        Toks = [P | _],
        take_kw("gap", Toks, T1),
        take_name(T1, Kind, T2),
        gap_kind(Kind ^ id_name, P ^ tk_pos, Policy)
    then
        Gap = yes(Policy),
        Rest = T2
    else
        Gap = no,
        Rest = Toks
    ).

    %@helper
:- pred gap_kind(string::in, pos::in, lgra_7_6a_gap_policy::out) is semidet.

gap_kind("hold", P, gp_hold(P)).
gap_kind("zero", P, gp_zero(P)).
gap_kind("skip", P, gp_skip(P)).

%-----------------------------------------------------------------------------%
% Rules -- [LGRA.6.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.6.1]
    %@spec [LGRA.6.2]
:- pred lgra_6_1_parse_rule(list(positioned)::in, decl_result::out) is det.

lgra_6_1_parse_rule(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("rule", Toks, T1), take_name(T1, Name, T2) then
        lgra_6_1_take_modifiers(T2, [], Mods, T3),
        ( if
            take_tok(colon, T3, T4),
            take_tok(newline, T4, T5),
            take_tok(indent, T5, T6)
        then
            lgra_5_6_parse_doc(T6, Doc, T7),
            parse_lhs_clauses(T7, [], LhsRes),
            (
                LhsRes = lhs_error(Err, EP),
                Result = td_error(Err, EP)
            ;
                LhsRes = lhs_ok(Lhs, T8),
                ( if Lhs = [] then
                    Result = td_error(pe_empty_lhs(Name ^ id_name), Pos)
                else if
                    take_tok(dedent, T8, T9),
                    take_tok(arrow, T9, T10),
                    take_tok(newline, T10, T11),
                    take_tok(indent, T11, T12)
                then
                    ltac_2_1_parse_rhs(T12, RhsRes),
                    (
                        RhsRes = rhs_error(RErr, REP),
                        Result = td_error(RErr, REP)
                    ;
                        RhsRes = rhs_ok(Rhs, Rest),
                        ( if
                            Rhs ^ rr_actions = [],
                            Rhs ^ rr_afters = []
                        then
                            Result = td_error(pe_empty_rhs(Name ^ id_name),
                                Pos)
                        else
                            Result = td_ok(td_rule(lgra_6_1_rule_decl(Name,
                                Mods, Doc, Lhs, Rhs, Pos)), Rest)
                        )
                    )
                else
                    Result = td_error(pe_expected("`->` and an indented rule "
                        ++ "body", peek(T8)), peek_pos(T8, Pos))
                )
            )
        else
            Result = td_error(pe_expected("`:` and an indented pattern block",
                peek(T3)), peek_pos(T3, Pos))
        )
    else
        Result = td_error(pe_expected("a rule name", peek(Toks)), Pos)
    ).

    % Zero or more, between the name and the `:`. A duplicate is the validator's
    % ([LGRA.6.6.7]).
    %
    %@spec [LGRA.6.1]
    %@spec [LGRA.6.6.1]
    %@spec [LGRA.6.6.2]
:- pred lgra_6_1_take_modifiers(list(positioned)::in,
                                list(lgra_6_1_rule_modifier)::in,
                                list(lgra_6_1_rule_modifier)::out,
                                list(positioned)::out) is det.

lgra_6_1_take_modifiers(Toks, Acc, Mods, Rest) :-
    ( if
        Toks = [P | _],
        P ^ tk_tok = name("cooldown"),
        take_kw("cooldown", Toks, T1),
        % The duration stops at the next modifier too.
        take_span_to(T1, [colon, name("cooldown"), name("by")], [], Span, T2),
        Span = [_ | _]
    then
        M = rm_cooldown(Span, P ^ tk_pos),
        lgra_6_1_take_modifiers(T2, [M | Acc], Mods, Rest)
    else if
        Toks = [P | _],
        take_kw("by", Toks, T1),
        take_tok(colon, T1, T2),
        lgra_6_1_rate_key(T2, Key, T3)
    then
        lgra_6_1_take_modifiers(T3, [rm_by(Key, P ^ tk_pos) | Acc], Mods,
            Rest)
    else
        Mods = reverse(Acc),
        Rest = Toks
    ).

    % A binding named `none` makes `none.x` a path: the `.` tells them apart.
    %
    %@spec [LGRA.6.1]
:- pred lgra_6_1_rate_key(list(positioned)::in, lgra_6_1_rate_key::out,
                          list(positioned)::out) is semidet.

lgra_6_1_rate_key(Toks, Key, Rest) :-
    ( if
        take_name(Toks, N, T1),
        N ^ id_name = "none",
        not take_tok(dot, T1, _)
    then
        Key = rk_none,
        Rest = T1
    else
        lgra_6_1_key_paths(Toks, [], Paths, Rest),
        Key = rk_paths(Paths)
    ).

    %@helper
:- pred lgra_6_1_key_paths(list(positioned)::in, list(lgra_6_1_key_path)::in,
                           list(lgra_6_1_key_path)::out, list(positioned)::out)
    is semidet.

lgra_6_1_key_paths(Toks, Acc, Paths, Rest) :-
    take_name(Toks, B, T1),
    take_tok(dot, T1, T2),
    take_name(T2, S, T3),
    ( if take_tok(comma, T3, T4) then
        lgra_6_1_key_paths(T4, [key_path(B, S) | Acc], Paths, Rest)
    else
        Paths = reverse([key_path(B, S) | Acc]),
        Rest = T3
    ).

    %@helper
:- type lhs_result
    --->    lhs_ok(list(lgra_8_1_lhs_clause), list(positioned))
    ;       lhs_error(parse_error, pos).

    %@helper
:- pred parse_lhs_clauses(list(positioned)::in,
                          list(lgra_8_1_lhs_clause)::in, lhs_result::out)
    is det.

parse_lhs_clauses(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, T1) then
        parse_lhs_clauses(T1, Acc, Result)
    else if peek(Toks) = name("then") then
        lgra_8_5_2_parse_then_line(Toks, LineRes),
        (
            LineRes = then_error(Err, EP),
            Result = lhs_error(Err, EP)
        ;
            LineRes = then_ok(Steps, T1),
            parse_lhs_clauses(T1, fold_then_line(Steps, Acc), Result)
        )
    else if Toks = [] then
        Result = lhs_ok(reverse(Acc), Toks)
    else if peek(Toks) = dedent then
        Result = lhs_ok(reverse(Acc), Toks)
    else
        lgra_8_1_parse_pattern(Toks, PatRes),
        (
            PatRes = pat_error(Err, EP),
            Result = lhs_error(Err, EP)
        ;
            PatRes = pat_ok(Pattern, T1),
            parse_lhs_clauses(T1, [lc_pattern(Pattern) | Acc], Result)
        )
    ).

    %@helper
:- type rhs_result
    --->    rhs_ok(lgra_6_1_rule_rhs, list(positioned))
    ;       rhs_error(parse_error, pos).

    %@spec [LGRA.6.1]
    %@spec [LTAC.2.1]
    %@spec [LTAC.2.3]
:- pred ltac_2_1_parse_rhs(list(positioned)::in, rhs_result::out) is det.

ltac_2_1_parse_rhs(Toks, Result) :-
    parse_lets(Toks, [], LetRes),
    (
        LetRes = lets_error(Err, EP),
        Result = rhs_error(Err, EP)
    ;
        LetRes = lets_ok(Lets, T1),
        parse_actions(T1, [], ActRes),
        (
            ActRes = acts_error(AErr, AEP),
            Result = rhs_error(AErr, AEP)
        ;
            ActRes = acts_ok(Actions, T2),
            parse_afters(T2, [], AfterRes),
            (
                AfterRes = afters_error(FErr, FEP),
                Result = rhs_error(FErr, FEP)
            ;
                AfterRes = afters_ok(Afters, T3),
                ( if take_tok(dedent, T3, T4) then
                    Result = rhs_ok(lgra_6_1_rule_rhs(Lets, Actions, Afters),
                        T4)
                else if T3 = [] then
                    Result = rhs_ok(lgra_6_1_rule_rhs(Lets, Actions, Afters),
                        [])
                else
                    Result = rhs_error(pe_expected("an action, an `after` "
                        ++ "clause, or the end of the rule", peek(T3)),
                        peek_pos(T3, pos(1, 0)))
                )
            )
        )
    ).

%-----------------------------------------------------------------------------%
% `let` -- [LGRA.6.1], [LGRA.6.7]
%-----------------------------------------------------------------------------%

    %@helper
:- type lets_result
    --->    lets_ok(list(lgra_6_1_let_decl), list(positioned))
    ;       lets_error(parse_error, pos).

    %@helper
:- pred parse_lets(list(positioned)::in, list(lgra_6_1_let_decl)::in,
                   lets_result::out) is det.

parse_lets(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_lets(TN, Acc, Result)
    else if peek(Toks) = name("let") then
        lgra_6_1_parse_let(Toks, LetRes),
        (
            LetRes = let_error(Err, EP),
            Result = lets_error(Err, EP)
        ;
            LetRes = let_ok(L, T1),
            parse_lets(T1, [L | Acc], Result)
        )
    else
        Result = lets_ok(reverse(Acc), Toks)
    ).

    %@helper
:- type let_result
    --->    let_ok(lgra_6_1_let_decl, list(positioned))
    ;       let_error(parse_error, pos).

    %@spec [LGRA.6.1]
    %@spec [LGRA.6.7.1]
    %@spec [LGRA.6.7.4]
:- pred lgra_6_1_parse_let(list(positioned)::in, let_result::out) is det.

lgra_6_1_parse_let(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("let", Toks, T1) then
        lgra_6_7_2_parse_binding(T1, First),
        (
            First = bind_error(Err, EP),
            Result = let_error(Err, EP)
        ;
            First = bind_ok(B, T2),
            ( if take_tok(indent, T2, T3) then
                parse_hanging_bindings(T3, [B], HangRes),
                (
                    HangRes = binds_error(HErr, HEP),
                    Result = let_error(HErr, HEP)
                ;
                    HangRes = binds_ok(Bs, T4),
                    Result = let_ok(lgra_6_1_let_decl(Bs, Pos), T4)
                )
            else
                Result = let_ok(lgra_6_1_let_decl([B], Pos), T2)
            )
        )
    else
        Result = let_error(pe_expected("`let`", peek(Toks)), Pos)
    ).

    %@helper
:- type binds_result
    --->    binds_ok(list(lgra_6_1_let_binding), list(positioned))
    ;       binds_error(parse_error, pos).

    %@helper
:- pred parse_hanging_bindings(list(positioned)::in,
                               list(lgra_6_1_let_binding)::in,
                               binds_result::out) is det.

parse_hanging_bindings(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_hanging_bindings(TN, Acc, Result)
    else if take_tok(dedent, Toks, T1) then
        Result = binds_ok(reverse(Acc), T1)
    else if Toks = [] then
        Result = binds_ok(reverse(Acc), [])
    else
        lgra_6_7_2_parse_binding(Toks, B),
        (
            B = bind_error(Err, EP),
            Result = binds_error(Err, EP)
        ;
            B = bind_ok(Bind, T1),
            parse_hanging_bindings(T1, [Bind | Acc], Result)
        )
    ).

    %@helper
:- type bind_result
    --->    bind_ok(lgra_6_1_let_binding, list(positioned))
    ;       bind_error(parse_error, pos).

    %@spec [LGRA.6.7.2]
    %@spec [LGRA.6.7.3]
:- pred lgra_6_7_2_parse_binding(list(positioned)::in, bind_result::out)
    is det.

lgra_6_7_2_parse_binding(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_tok(lparen, Toks, T1) then
        take_capture_names(T1, [], Names, T2),
        ( if Names = [], true then
            Result = bind_error(pe_expected("a name in the capture list",
                peek(T1)), Pos)
        else if take_tok(rparen, T2, T3), take_tok(assign, T3, T4) then
            take_binding_value(T4, Pos, ValRes),
            (
                ValRes = val_error(Err, EP),
                Result = bind_error(Err, EP)
            ;
                ValRes = val_ok(E, T5),
                Result = bind_ok(lb_capture(Names, E, Pos), T5)
            )
        else
            Result = bind_error(pe_expected("`)` and `=` after the capture "
                ++ "list", peek(T2)), peek_pos(T2, Pos))
        )
    else if take_name(Toks, Name, T1) then
        ( if take_tok(colon, T1, T2), llex_10_8_3_take_type(T2, Ty, T3) then
            ( if take_tok(question, T3, T4) then
                Ann = yes(lgra_6_7_2_annotation(Ty, nullable)),
                T5 = T4
            else
                Ann = yes(lgra_6_7_2_annotation(Ty, non_null)),
                T5 = T3
            )
        else
            Ann = no,
            T5 = T1
        ),
        ( if take_tok(assign, T5, T6) then
            take_binding_value(T6, Pos, ValRes),
            (
                ValRes = val_error(Err, EP),
                Result = bind_error(Err, EP)
            ;
                ValRes = val_ok(E, T7),
                Result = bind_ok(lb_simple(Name, Ann, E, Pos), T7)
            )
        else
            Result = bind_error(pe_expected("`=` in the `let` binding",
                peek(T5)), peek_pos(T5, Pos))
        )
    else
        Result = bind_error(pe_expected("a name or `(` after `let`",
            peek(Toks)), Pos)
    ).

    %@helper
:- pred take_capture_names(list(positioned)::in, list(ident)::in,
                           list(ident)::out, list(positioned)::out) is det.

take_capture_names(Toks, Acc, Names, Rest) :-
    ( if take_name(Toks, N, T1) then
        ( if take_tok(comma, T1, T2) then
            take_capture_names(T2, [N | Acc], Names, Rest)
        else
            Names = reverse([N | Acc]),
            Rest = T1
        )
    else
        Names = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- type val_result
    --->    val_ok(lgra_9_3_1_expr, list(positioned))
    ;       val_error(parse_error, pos).

    %@helper
:- pred take_binding_value(list(positioned)::in, pos::in, val_result::out)
    is det.

take_binding_value(Toks, Pos, Result) :-
    take_where_span(Toks, 0, [], Span, T1),
    (
        Span = [],
        Result = val_error(pe_expected("an expression", peek(Toks)),
            peek_pos(Toks, Pos))
    ;
        Span = [_ | _],
        lgra_9_1_parse_expr(Span, ExprRes),
        (
            ExprRes = ex_error(Err, EP),
            Result = val_error(Err, EP)
        ;
            ExprRes = ex_ok(E, _),
            ( if take_tok(newline, T1, T2) then
                Result = val_ok(E, T2)
            else
                Result = val_ok(E, T1)
            )
        )
    ).

%-----------------------------------------------------------------------------%
% Actions -- [LGRA.10.1]
%-----------------------------------------------------------------------------%

    %@helper
:- type acts_result
    --->    acts_ok(list(lgra_10_1_action), list(positioned))
    ;       acts_error(parse_error, pos).

    %@helper
:- pred parse_actions(list(positioned)::in, list(lgra_10_1_action)::in,
                      acts_result::out) is det.

parse_actions(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_actions(TN, Acc, Result)
    else if peek(Toks) = name(Kw), lgra_10_1_action_keyword(Kw) then
        lgra_10_1_parse_action(Toks, ActRes),
        (
            ActRes = act_error(Err, EP),
            Result = acts_error(Err, EP)
        ;
            ActRes = act_ok(A, T1),
            parse_actions(T1, [A | Acc], Result)
        )
    else
        Result = acts_ok(reverse(Acc), Toks)
    ).

    %@spec [LGRA.10.1]
:- pred lgra_10_1_action_keyword(string::in) is semidet.

lgra_10_1_action_keyword("log").
lgra_10_1_action_keyword("call").
lgra_10_1_action_keyword("emit").
lgra_10_1_action_keyword("publish").
lgra_10_1_action_keyword("cache").
lgra_10_1_action_keyword("cache_delete").
lgra_10_1_action_keyword("record_event").
lgra_10_1_action_keyword("withdraw").

    %@helper
:- type act_result
    --->    act_ok(lgra_10_1_action, list(positioned))
    ;       act_error(parse_error, pos).

    %@spec [LGRA.10.1]
    %@spec [LGRA.10.2]
:- pred lgra_10_1_parse_action(list(positioned)::in, act_result::out) is det.

lgra_10_1_parse_action(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    lgra_10_1_parse_head(Toks, HeadRes),
    (
        HeadRes = head_error(Err, EP),
        Result = act_error(Err, EP)
    ;
        HeadRes = head_ok(Head, T1),
        lgra_10_3_1_parse_args(T1, [], ArgRes),
        (
            ArgRes = args2_error(AErr, AEP),
            Result = act_error(AErr, AEP)
        ;
            ArgRes = args2_ok(Args, T2a),
            lcrs_6_2_3_take_as(Head, T2a, AsRes),
            (
                AsRes = as_error(SErr, SEP),
                Result = act_error(SErr, SEP)
            ;
                AsRes = as_ok(LineAs, T2),
                finish_action(Head, Args, LineAs, T2, Pos, Result)
            )
        )
    ).

    %@helper
:- pred finish_action(lgra_10_1_action_head::in,
                      list(lgra_10_3_1_action_arg)::in,
                      maybe(lgra_9_3_1_expr)::in, list(positioned)::in, pos::in,
                      act_result::out) is det.

finish_action(Head, Args, LineAs, T2, Pos, Result) :-
    ( if take_tok(newline, T2, T3) then
        ( if take_tok(indent, T3, T4) then
            lcco_2_1_action_block(Head, T4, Pos, BlockRes),
            (
                BlockRes = block_error(BErr, BEP),
                Result = act_error(BErr, BEP)
            ;
                BlockRes = block_ok(Block, BlockAs, T5),
                ( if LineAs = yes(_), BlockAs = yes(_) then
                    Result = act_error(pe_expected("one `as` on a `call`, "
                        ++ "not one on its line and another in its block",
                        name("as")), Pos)
                else
                    As = ( if LineAs = yes(_) then LineAs else BlockAs ),
                    Result = act_ok(lgra_10_1_action(Head, Args, Block, As,
                        Pos), T5)
                )
            )
        else
            Result = act_ok(lgra_10_1_action(Head, Args, ab_none, LineAs, Pos),
                T3)
        )
    else if T2 = [] then
        Result = act_ok(lgra_10_1_action(Head, Args, ab_none, LineAs, Pos), [])
    else
        Result = act_error(pe_expected("the end of the action",
            peek(T2)), peek_pos(T2, Pos))
    ).

    %@helper
:- type as_result
    --->    as_ok(maybe(lgra_9_3_1_expr), list(positioned))
    ;       as_error(parse_error, pos).

    % `call` alone takes one. A kwarg after it is the caller's "expected the end
    % of the action". `as:` parses as a kwarg, which
    % `dsc.validate.lrst_1_3_legacy_as_colon` refuses.
    %
    %@spec [LCRS.6.2.3]
    %@spec [LRST.1.1]
:- pred lcrs_6_2_3_take_as(lgra_10_1_action_head::in, list(positioned)::in,
                           as_result::out) is det.

lcrs_6_2_3_take_as(Head, Toks, Result) :-
    ( if Head = ah_call(_), take_kw("as", Toks, T1) then
        lgra_9_3_1_or(T1, ExRes),
        (
            ExRes = ex_error(Err, EP),
            Result = as_error(Err, EP)
        ;
            ExRes = ex_ok(E, T2),
            Result = as_ok(yes(E), T2)
        )
    else
        Result = as_ok(no, Toks)
    ).

    %@helper
:- type block_result
    --->    block_ok(lgra_10_1_action_block, maybe(lgra_9_3_1_expr),
                     list(positioned))
    ;       block_error(parse_error, pos).

    %@spec [LGRA.10.8]
    %@spec [LCCO.2.1]
:- pred lcco_2_1_action_block(lgra_10_1_action_head::in, list(positioned)::in,
                           pos::in, block_result::out) is det.

lcco_2_1_action_block(Head, Toks, Pos, Result) :-
    (
        Head = ah_call(_),
        lcco_2_1_call_block(Toks, [], [], no, Result)
    ;
        % `record_event` parses, block and all, for `dsc.validate`'s refusal.
        ( Head = ah_emit(_) ; Head = ah_publish(_)
        ; Head = ah_record_event(_) ),
        parse_kwarg_lines(Toks, [], KwRes),
        (
            KwRes = kwlines_error(Err, EP),
            Result = block_error(Err, EP)
        ;
            KwRes = kwlines_ok(Kwargs, T1),
            ( if take_tok(dedent, T1, T2) then
                Result = block_ok(ab_kwargs(Kwargs), no, T2)
            else if T1 = [] then
                Result = block_ok(ab_kwargs(Kwargs), no, [])
            else
                Result = block_error(pe_expected("a `name: value` line",
                    peek(T1)), peek_pos(T1, Pos))
            )
        )
    ;
        ( Head = ah_log(_, _) ; Head = ah_cache ; Head = ah_cache_delete
        ; Head = ah_withdraw(_) ),
        Result = block_error(pe_action_block(describe_head(Head)), Pos)
    ).

    %@helper
:- type kwlines_result
    --->    kwlines_ok(list(lgra_10_3_1_action_arg), list(positioned))
    ;       kwlines_error(parse_error, pos).

    %@helper
:- pred parse_kwarg_lines(list(positioned)::in,
                          list(lgra_10_3_1_action_arg)::in,
                          kwlines_result::out) is det.

parse_kwarg_lines(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_kwarg_lines(TN, Acc, Result)
    else if peek(Toks) = name(_) then
        lgra_10_3_1_parse_args(Toks, [], ArgRes),
        (
            ArgRes = args2_error(Err, EP),
            Result = kwlines_error(Err, EP)
        ;
            ArgRes = args2_ok(Args, T1),
            (
                Args = [],
                Result = kwlines_ok(reverse(Acc), Toks)
            ;
                Args = [_ | _],
                parse_kwarg_lines(T1, reverse(Args) ++ Acc, Result)
            )
        )
    else
        Result = kwlines_ok(reverse(Acc), Toks)
    ).

    % Kwargs and continuations may interleave. The `as` line closes the arguments
    % ([LCRS.6.2.3]); a continuation below it is no argument.
    %
    %@spec [LCCO.2.1]
    %@spec [LCRS.6.2.3]
:- pred lcco_2_1_call_block(list(positioned)::in,
                         list(lgra_10_3_1_action_arg)::in,
                         list(lcco_2_1_continuation)::in,
                         maybe(lgra_9_3_1_expr)::in,
                         block_result::out) is det.

lcco_2_1_call_block(Toks, Kwargs, Conts, As, Result) :-
    ( if take_tok(newline, Toks, TN) then
        lcco_2_1_call_block(TN, Kwargs, Conts, As, Result)
    else if take_tok(dedent, Toks, T1) then
        Result = block_ok(ab_call(reverse(Kwargs), reverse(Conts)), As, T1)
    else if Toks = [] then
        Result = block_ok(ab_call(reverse(Kwargs), reverse(Conts)), As, [])
    else if peek(Toks) = name(Kw), lcco_2_1_continuation_keyword(Kw) then
        lcco_2_1_parse_continuation(Toks, ContRes),
        (
            ContRes = cont_error(Err, EP),
            Result = block_error(Err, EP)
        ;
            ContRes = cont_ok(C, T1),
            lcco_2_1_call_block(T1, Kwargs, [C | Conts], As, Result)
        )
    else if
        peek(Toks) = name("as"),
        take_kw("as", Toks, TA),
        not take_tok(colon, TA, _)
    then
        P = peek_pos(Toks, pos(1, 0)),
        lgra_9_3_1_or(TA, ExRes),
        (
            ExRes = ex_error(Err, EP),
            Result = block_error(Err, EP)
        ;
            ExRes = ex_ok(E, T1),
            ( if As = yes(_) then
                Result = block_error(pe_expected("one `as` line in a `call` "
                    ++ "block", name("as")), P)
            else if
                ( peek(T1) = newline
                ; peek(T1) = dedent
                ; T1 = []
                )
            then
                lcco_2_1_call_block(T1, Kwargs, Conts, yes(E), Result)
            else
                Result = block_error(pe_expected("the end of the `as` line",
                    peek(T1)), peek_pos(T1, P))
            )
        )
    else if peek(Toks) = name(_), As = yes(_) then
        Result = block_error(pe_expected("nothing but continuations after "
            ++ "the `as` line; `as` is the call's last clause ([LCRS.6.2.3])",
            peek(Toks)), peek_pos(Toks, pos(1, 0)))
    else if peek(Toks) = name(_) then
        lgra_10_3_1_parse_args(Toks, [], ArgRes),
        (
            ArgRes = args2_error(Err, EP),
            Result = block_error(Err, EP)
        ;
            ArgRes = args2_ok(Args, T1),
            (
                Args = [],
                Result = block_error(pe_expected("a `name: value` line or a "
                    ++ "continuation", peek(Toks)),
                    peek_pos(Toks, pos(1, 0)))
            ;
                Args = [_ | _],
                lcco_2_1_call_block(T1, reverse(Args) ++ Kwargs, Conts, As,
                    Result)
            )
        )
    else
        Result = block_error(pe_expected("a `name: value` line or a "
            ++ "continuation", peek(Toks)), peek_pos(Toks, pos(1, 0)))
    ).

    %@spec [LCCO.2.1]
:- pred lcco_2_1_continuation_keyword(string::in) is semidet.

lcco_2_1_continuation_keyword("on").
lcco_2_1_continuation_keyword("timeout").
lcco_2_1_continuation_keyword("error").

    %@helper
:- type cont_result
    --->    cont_ok(lcco_2_1_continuation, list(positioned))
    ;       cont_error(parse_error, pos).

    %@spec [LCCO.2.1]
:- pred lcco_2_1_parse_continuation(list(positioned)::in, cont_result::out)
    is det.

lcco_2_1_parse_continuation(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("error", Toks, T1) then
        ( if take_tok(colon, T1, _) then
            Pattern = no,
            T2 = T1
        else
            take_dotted_path(T1, [], Path, T2),
            ( if Path = [] then Pattern = no else Pattern = yes(Path) )
        ),
        parse_continuation_body(T2, Pos, BodyRes),
        (
            BodyRes = cbody_error(Err, EP),
            Result = cont_error(Err, EP)
        ;
            BodyRes = cbody_ok(Actions, T3),
            Result = cont_ok(cont_error(Pattern, Actions, Pos), T3)
        )
    else if take_kw("on", Toks, T1) then
        parse_continuation_head(T1, Pos, cont_kind_on, Result)
    else if take_kw("timeout", Toks, T1) then
        parse_continuation_head(T1, Pos, cont_kind_timeout, Result)
    else
        Result = cont_error(pe_expected("`on`, `timeout` or `error`",
            peek(Toks)), Pos)
    ).

    %@helper
:- type cont_kind
    --->    cont_kind_on
    ;       cont_kind_timeout.

    %@helper
:- pred parse_continuation_head(list(positioned)::in, pos::in, cont_kind::in,
                                cont_result::out) is det.

parse_continuation_head(Toks, Pos, Kind, Result) :-
    take_span_to(Toks, [colon], [], Span, T1),
    (
        Span = [],
        Result = cont_error(pe_expected("an expression before the `:`",
            peek(Toks)), peek_pos(Toks, Pos))
    ;
        Span = [_ | _],
        lgra_9_1_parse_expr(Span, ExprRes),
        (
            ExprRes = ex_error(Err, EP),
            Result = cont_error(Err, EP)
        ;
            ExprRes = ex_ok(E, _),
            parse_continuation_body(T1, Pos, BodyRes),
            (
                BodyRes = cbody_error(BErr, BEP),
                Result = cont_error(BErr, BEP)
            ;
                BodyRes = cbody_ok(Actions, T2),
                (
                    Kind = cont_kind_on,
                    Result = cont_ok(cont_on(E, Actions, Pos), T2)
                ;
                    Kind = cont_kind_timeout,
                    Result = cont_ok(cont_timeout(E, Actions, Pos), T2)
                )
            )
        )
    ).

    %@helper
:- type cbody_result
    --->    cbody_ok(list(lgra_10_1_action), list(positioned))
    ;       cbody_error(parse_error, pos).

    %@helper
:- pred parse_continuation_body(list(positioned)::in, pos::in,
                                cbody_result::out) is det.

parse_continuation_body(Toks, Pos, Result) :-
    ( if
        take_tok(colon, Toks, T1),
        take_tok(newline, T1, T2),
        take_tok(indent, T2, T3)
    then
        parse_actions(T3, [], ActRes),
        (
            ActRes = acts_error(Err, EP),
            Result = cbody_error(Err, EP)
        ;
            ActRes = acts_ok(Actions, T4),
            ( if take_tok(dedent, T4, T5) then
                Result = cbody_ok(Actions, T5)
            else if T4 = [] then
                Result = cbody_ok(Actions, [])
            else
                Result = cbody_error(pe_expected("the end of the continuation",
                    peek(T4)), peek_pos(T4, Pos))
            )
        )
    else
        Result = cbody_error(pe_expected("`:` and an indented action block",
            peek(Toks)), peek_pos(Toks, Pos))
    ).

    %@helper
:- type head_result
    --->    head_ok(lgra_10_1_action_head, list(positioned))
    ;       head_error(parse_error, pos).

    %@spec [LGRA.10.1]
    %@spec [LGRA.10.1.1]
:- pred lgra_10_1_parse_head(list(positioned)::in, head_result::out) is det.

lgra_10_1_parse_head(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("log", Toks, T1) then
        ( if
            take_name(T1, Level, T2),
            T2 = [P | T3],
            string_token(P ^ tk_tok, S)
        then
            ( if lgra_10_1_1_log_level_of(Level ^ id_name, Known) then
                LL = Known
            else
                LL = ll_unknown(Level ^ id_name)
            ),
            Result = head_ok(ah_log(LL, S), T3)
        else if take_name(T1, _, T2) then
            Result = head_error(pe_expected("a string after the log level",
                peek(T2)), peek_pos(T2, Pos))
        else
            Result = head_error(pe_expected("a log level and a string",
                peek(T1)), peek_pos(T1, Pos))
        )
    else if take_kw("call", Toks, T1) then
        ( if lgra_10_1_take_service_ref(T1, Ref, T2) then
            Result = head_ok(ah_call(Ref), T2)
        else
            Result = head_error(pe_expected("a service name", peek(T1)),
                peek_pos(T1, Pos))
        )
    else if take_kw("emit", Toks, T1) then
        head_with_type_ref(T1, Pos, (func(R) = ah_emit(R)), Result)
    else if take_kw("publish", Toks, T1) then
        head_with_type_ref(T1, Pos, (func(R) = ah_publish(R)), Result)
    else if take_kw("record_event", Toks, T1) then
        head_with_type_ref(T1, Pos, (func(R) = ah_record_event(R)), Result)
    else if take_kw("withdraw", Toks, T1) then
        % The NAME is a binding, not a schema.
        head_with_name(T1, Pos, (func(N) = ah_withdraw(N)), Result)
    else if take_kw("cache_delete", Toks, T1) then
        Result = head_ok(ah_cache_delete, T1)
    else if take_kw("cache", Toks, T1) then
        Result = head_ok(ah_cache, T1)
    else
        Result = head_error(pe_expected("an action", peek(Toks)), Pos)
    ).

    %@helper
:- pred head_with_name(list(positioned), pos,
                       func(ident) = lgra_10_1_action_head, head_result).
    %@helper
:- mode head_with_name(in, in, func(in) = out is det, out) is det.

head_with_name(Toks, Pos, Make, Result) :-
    ( if take_name(Toks, N, T1) then
        Result = head_ok(Make(N), T1)
    else
        Result = head_error(pe_expected("a binding name", peek(Toks)), Pos)
    ).

    %@helper
:- pred head_with_type_ref(list(positioned), pos,
                           func(lgra_8_1_type_ref) = lgra_10_1_action_head,
                           head_result).
    %@helper
:- mode head_with_type_ref(in, in, func(in) = out is det, out) is det.

head_with_type_ref(Toks, Pos, Make, Result) :-
    ( if lgra_8_1_take_type_ref(Toks, R, T1) then
        Result = head_ok(Make(R), T1)
    else
        Result = head_error(pe_expected("a schema name", peek(Toks)), Pos)
    ).

    %@helper
:- pred string_token(token::in, string::out) is semidet.

string_token(single_str(S), S).
string_token(triple_str(S), S).

    %@spec [LGRA.10.1.1]
:- pred lgra_10_1_1_log_level_of(string::in, lgra_10_1_1_log_level::out)
    is semidet.

lgra_10_1_1_log_level_of(Name, Level) :-
    Lower = to_lower(Name),
    ( Lower = "debug", Level = ll_debug
    ; Lower = "info", Level = ll_info
    ; Lower = "warning", Level = ll_warning
    ; Lower = "error", Level = ll_error
    ; Lower = "critical", Level = ll_critical
    ).

    %@spec [LGRA.10.1]
:- pred lgra_10_1_take_service_ref(list(positioned)::in,
                                   lgra_10_1_service_ref::out,
                                   list(positioned)::out) is semidet.

lgra_10_1_take_service_ref(Toks, Ref, Rest) :-
    take_dotted_path(Toks, [], First, Rest),
    First = [_ | _],
    Ref = sr_bare(First).

    %@helper
:- pred take_dotted_path(list(positioned)::in, list(ident)::in,
                         list(ident)::out, list(positioned)::out) is det.

take_dotted_path(Toks, Acc, Path, Rest) :-
    ( if take_name(Toks, N, T1) then
        ( if take_tok(dot, T1, T2), peek(T2) = name(_) then
            take_dotted_path(T2, [N | Acc], Path, Rest)
        else
            Path = reverse([N | Acc]),
            Rest = T1
        )
    else
        Path = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- type args2_result
    --->    args2_ok(list(lgra_10_3_1_action_arg), list(positioned))
    ;       args2_error(parse_error, pos).

    %@spec [LGRA.10.3.1]
    %@spec [LGRA.10.3.2]
:- pred lgra_10_3_1_parse_args(list(positioned)::in,
                               list(lgra_10_3_1_action_arg)::in,
                               args2_result::out) is det.

lgra_10_3_1_parse_args(Toks, Acc, Result) :-
    ( if take_name(Toks, N, T1), take_tok(colon, T1, T2) then
        lgra_9_3_1_or(T2, ValRes),
        (
            ValRes = ex_error(Err, EP),
            Result = args2_error(Err, EP)
        ;
            ValRes = ex_ok(E, T3),
            lgra_10_3_1_parse_args(T3,
                [aa_kwarg(N, E, N ^ id_pos) | Acc], Result)
        )
    else if take_name(Toks, N, T1), N ^ id_name \= "as" then
        % A bare `as` opens the correlation clause.
        lgra_10_3_1_parse_args(T1, [aa_flag(N) | Acc], Result)
    else
        Result = args2_ok(reverse(Acc), Toks)
    ).

%-----------------------------------------------------------------------------%
% `after` clauses -- [LGRA.6.1], [LTAC.2.1], [LTAC.2.2]
%-----------------------------------------------------------------------------%

    %@helper
:- type afters_result
    --->    afters_ok(list(ltac_2_1_after_clause), list(positioned))
    ;       afters_error(parse_error, pos).

    %@helper
:- pred parse_afters(list(positioned)::in, list(ltac_2_1_after_clause)::in,
                     afters_result::out) is det.

parse_afters(Toks, Acc, Result) :-
    ( if take_tok(newline, Toks, TN) then
        parse_afters(TN, Acc, Result)
    else if peek(Toks) = name("after") then
        ltac_2_1_parse_after(Toks, AfterRes),
        (
            AfterRes = after_error(Err, EP),
            Result = afters_error(Err, EP)
        ;
            AfterRes = after_ok(A, T1),
            parse_afters(T1, [A | Acc], Result)
        )
    else
        Result = afters_ok(reverse(Acc), Toks)
    ).

    %@helper
:- type after_result
    --->    after_ok(ltac_2_1_after_clause, list(positioned))
    ;       after_error(parse_error, pos).

    % The duration is one `UNIT_LIT` token ([LTAC.2.2]). Its dimension is
    % `ltac_7_1_after_duration`'s to judge.
    %
    %@spec [LTAC.2.1]
    %@spec [LGRA.6.1]
    %@spec [LTAC.2.2]
:- pred ltac_2_1_parse_after(list(positioned)::in, after_result::out) is det.

ltac_2_1_parse_after(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("after", Toks, T1) then
        ( if
            T1 = [DurTok | T2],
            DurTok ^ tk_tok = unit_lit(Magnitude, Suffix)
        then
            Dur = ex_unit(Magnitude, Suffix, DurTok ^ tk_pos),
            parse_after_tail(Dur, T2, Pos, Result)
        else
            Result = after_error(pe_expected("a time-unit literal after "
                ++ "`after`, like `30_s` ([LGRA.6.1], [LTAC.2.2])",
                peek(T1)), peek_pos(T1, Pos))
        )
    else
        Result = after_error(pe_expected("`after`", peek(Toks)), Pos)
    ).

    %@helper
:- pred parse_after_tail(lgra_9_3_1_expr::in, list(positioned)::in, pos::in,
                         after_result::out) is det.

parse_after_tail(Dur, Toks, Pos, Result) :-
    ( if take_kw("as", Toks, TA) then
        take_span_to(TA, [colon], [], AsSpan, T1),
        (
            AsSpan = [],
            Result = after_error(pe_expected("an expression after `as`",
                peek(TA)), peek_pos(TA, Pos))
        ;
            AsSpan = [_ | _],
            lgra_9_1_parse_expr(AsSpan, AsRes),
            (
                AsRes = ex_error(Err, EP),
                Result = after_error(Err, EP)
            ;
                AsRes = ex_ok(AsE, _),
                parse_after_block(Dur, yes(AsE), T1, Pos, Result)
            )
        )
    else
        parse_after_block(Dur, no, Toks, Pos, Result)
    ).

    %@helper
:- pred parse_after_block(lgra_9_3_1_expr::in, maybe(lgra_9_3_1_expr)::in,
                          list(positioned)::in, pos::in, after_result::out)
    is det.

parse_after_block(Dur, As, Toks, Pos, Result) :-
    ( if
        take_tok(colon, Toks, T1),
        take_tok(newline, T1, T2),
        take_tok(indent, T2, T3)
    then
        parse_actions(T3, [], ActRes),
        (
            ActRes = acts_error(Err, EP),
            Result = after_error(Err, EP)
        ;
            ActRes = acts_ok(Actions, T4),
            parse_afters(T4, [], NestedRes),
            (
                NestedRes = afters_error(NErr, NEP),
                Result = after_error(NErr, NEP)
            ;
                NestedRes = afters_ok(Nested, T5),
                ( if take_tok(dedent, T5, T6) then
                    Result = after_ok(ltac_2_1_after_clause(Dur, As, Actions,
                        Nested, Pos), T6)
                else if T5 = [] then
                    Result = after_ok(ltac_2_1_after_clause(Dur, As, Actions,
                        Nested, Pos), [])
                else
                    Result = after_error(pe_expected("the end of the `after` "
                        ++ "block", peek(T5)), peek_pos(T5, Pos))
                )
            )
        )
    else
        Result = after_error(pe_expected("`:` and an indented block after "
            ++ "`after`", peek(Toks)), peek_pos(Toks, Pos))
    ).

%-----------------------------------------------------------------------------%
% Patterns -- [LGRA.8.1]
%-----------------------------------------------------------------------------%

    %@helper
:- type pattern_result
    --->    pat_ok(lgra_8_1_pattern, list(positioned))
    ;       pat_error(parse_error, pos).

    % `latest` opens a sequence only when a NAME follows it ([LGRA.8.3.1]).
    %
    %@spec [LGRA.8.1]
    %@spec [LGRA.8.3.2]
    %@spec [LGRA.8.4.2]
    %@spec [LGRA.8.5.10]
    %@spec [LGRA.8.5.16]
:- pred lgra_8_1_parse_pattern(list(positioned)::in, pattern_result::out)
    is det.

lgra_8_1_parse_pattern(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("no", Toks, T1) then
        ( if take_tok(lparen, T1, T2) then
            lgra_8_1_parse_body(T2, BodyRes),
            (
                BodyRes = body_error(Err, EP),
                Result = pat_error(Err, EP)
            ;
                BodyRes = body_ok(Body, T3),
                ( if take_tok(rparen, T3, T4), end_of_clause(T4, T5) then
                    Result = pat_ok(
                        pat_negated(Body, np_parenthesised, Pos), T5)
                else
                    Result = pat_error(pe_expected("`)` ending the negated "
                        ++ "pattern", peek(T3)), peek_pos(T3, Pos))
                )
            )
        else
            lgra_8_1_parse_body(T1, BodyRes),
            (
                BodyRes = body_error(Err, EP),
                Result = pat_error(Err, EP)
            ;
                BodyRes = body_ok(Body, T2),
                ( if end_of_clause(T2, T3) then
                    Result = pat_ok(pat_negated(Body, np_bare, Pos), T3)
                else
                    Result = pat_error(pe_expected("the end of the negated "
                        ++ "pattern", peek(T2)), peek_pos(T2, Pos))
                )
            )
        )
    else
        ( if
            peek(Toks) = name("latest"),
            take_kw("latest", Toks, TL),
            TL = [Q | _],
            Q ^ tk_tok = name(_)
        then
            Latest = sl_latest,
            T1 = TL
        else
            Latest = sl_plain,
            T1 = Toks
        ),
        lgra_8_1_parse_body(T1, BodyRes),
        (
            BodyRes = body_error(Err, EP),
            Result = pat_error(Err, EP)
        ;
            BodyRes = body_ok(Head, T2),
            lgra_8_5_2_take_then_steps(T2, [], StepsRes),
            (
                StepsRes = steps_error(SErr, SEP),
                Result = pat_error(SErr, SEP)
            ;
                StepsRes = steps_ok(Steps, T3),
            (
                Steps = [],
                (
                    Latest = sl_latest,
                    % A sequence with no steps: the LHS loop folds the next
                    % lines' `then`s into it, and one with none stands.
                    ( if end_of_clause(T3, T4) then
                        Result = pat_ok(pat_sequence(sl_latest, Head, [],
                            Pos), T4)
                    else
                        Result = pat_error(pe_expected("`then` after a "
                            ++ "`latest` pattern", peek(T3)),
                            peek_pos(T3, pos(1, 0)))
                    )
                ;
                    Latest = sl_plain,
                    ( if end_of_clause(T3, T4) then
                        Result = pat_ok(pat_simple(Head), T4)
                    else
                        Result = pat_error(pe_expected("the end of the "
                            ++ "pattern", peek(T3)), peek_pos(T3, pos(1, 0)))
                    )
                )
            ;
                Steps = [_ | _],
                % A trailing `where` is the last step's ([LGRA.8.5.10]), as on a
                % line-leading `then`.
                lgra_8_3_4_take_where(T3, Where, T4),
                (
                    Where = where_bad(WErr, WEP),
                    Result = pat_error(WErr, WEP)
                ;
                    Where = where_missing(WP),
                    Result = pat_error(pe_expected("an expression after "
                        ++ "`where`", dedent), WP)
                ;
                    Where = where_none,
                    finish_sequence(Latest, Head, Steps, Pos, T4, Result)
                ;
                    ( Where = where_yes(E), MaybeCap = no
                    ; Where = where_capture(E, Cap), MaybeCap = yes(Cap)
                    ),
                    ( if last_step_has_where(Steps) then
                        Result = pat_error(pe_expected("the end of the "
                            ++ "sequence pattern: its last step already has "
                            ++ "a `where` ([LGRA.8.5.10])", peek(T3)),
                            peek_pos(T3, pos(1, 0)))
                    else
                        finish_sequence(Latest, Head,
                            set_last_step_where(E, MaybeCap, Steps), Pos, T4,
                            Result)
                    )
                )
            )
            )
        )
    ).

    % `steps_error` is a `then` that could not parse; a line with none is
    % `steps_ok` with no steps.
    %
    %@spec [LGRA.8.5.2]
    %@spec [LGRA.8.5.8]
    %@spec [LGRA.8.5.7]
:- pred lgra_8_5_2_take_then_steps(list(positioned)::in,
                                   list(lgra_8_5_2_then_step)::in,
                                   steps_result::out) is det.

lgra_8_5_2_take_then_steps(Toks, Acc, Result) :-
    ( if
        Toks = [P | _],
        take_kw("then", Toks, T0),
        take_step_latest(T0, Latest, T1),
        % `pattern_body` also ends in an optional `within_clause` ([LGRA.8.1]):
        % here the `within` is the step's, not the body's.
        lgra_8_1_parse_body_mode(T1, within_is_the_steps, body_ok(Body, T2)),
        take_kw("within", T2, T3),
        take_span_to(T3, [name("then"), name("where")], [], Span, T4),
        Span = [_ | _]
    then
        ( if lgra_2_8_1_time_expr(Span) then
            Step = lgra_8_5_2_then_step(Latest, Body, Span, P ^ tk_pos),
            lgra_8_5_2_take_then_steps(T4, [Step | Acc], Result)
        else
            Result = steps_error(time_expr_error("within", Span),
                peek_pos(Span, P ^ tk_pos))
        )
    else
        Result = steps_ok(reverse(Acc), Toks)
    ).

    %@helper
:- type steps_result
    --->    steps_ok(list(lgra_8_5_2_then_step), list(positioned))
    ;       steps_error(parse_error, pos).

    % `then latest X`, for [LTHE.5.4]'s refusal.
    %
    %@helper
:- pred take_step_latest(list(positioned)::in, sequence_latest::out,
                         list(positioned)::out) is det.

take_step_latest(Toks, Latest, Rest) :-
    ( if
        peek(Toks) = name("latest"),
        take_kw("latest", Toks, TL),
        TL = [Q | _],
        Q ^ tk_tok = name(_)
    then
        Latest = sl_latest,
        Rest = TL
    else
        Latest = sl_plain,
        Rest = Toks
    ).

    %@helper
:- type then_line_result
    --->    then_ok(list(lgra_8_5_2_then_step), list(positioned))
    ;       then_error(parse_error, pos).

    % A pattern line that opens with `then`, below the pattern it folds into
    % ([LTHE.4.1]). A `where` after the `within` is the step's ([LGRA.8.5.10]).
    %
    %@spec [LGRA.8.5.2]
    %@spec [LGRA.8.5.7]
:- pred lgra_8_5_2_parse_then_line(list(positioned)::in, then_line_result::out)
    is det.

lgra_8_5_2_parse_then_line(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if take_kw("then", Toks, T0) then
        take_step_latest(T0, Latest, T1),
        lgra_8_1_parse_body_mode(T1, within_is_the_steps, BodyRes),
        (
            BodyRes = body_error(Err, EP),
            Result = then_error(Err, EP)
        ;
            BodyRes = body_ok(Body, T2),
            ( if
                take_kw("within", T2, T3),
                take_span_to(T3, [name("then"), name("where")], [], Span, T4),
                Span = [_ | _]
            then
                % Ahead of the loop, so the first bad duration is the one named.
                ( if not lgra_2_8_1_time_expr(Span) then
                    Result = then_error(time_expr_error("within", Span),
                        peek_pos(Span, Pos))
                else
                lgra_8_5_2_take_then_steps(T4, [], MoreRes),
                (
                    MoreRes = steps_error(SErr, SEP),
                    Result = then_error(SErr, SEP)
                ;
                    MoreRes = steps_ok(More, T5),
                Steps = [lgra_8_5_2_then_step(Latest, Body, Span, Pos) | More],
                lgra_8_3_4_take_where(T5, Where, T6),
                (
                    Where = where_bad(WErr, WEP),
                    Result = then_error(WErr, WEP)
                ;
                    Where = where_missing(WP),
                    Result = then_error(pe_expected("an expression after "
                        ++ "`where`", dedent), WP)
                ;
                    Where = where_none,
                    finish_then_line(Steps, T6, Result)
                ;
                    ( Where = where_yes(E), MaybeCap = no
                    ; Where = where_capture(E, Cap), MaybeCap = yes(Cap)
                    ),
                    ( if last_step_has_where(Steps) then
                        Result = then_error(pe_expected("the end of the "
                            ++ "`then` pattern", peek(T5)), peek_pos(T5, Pos))
                    else
                        finish_then_line(
                            set_last_step_where(E, MaybeCap, Steps), T6,
                            Result)
                    )
                )
                )
                )
            else
                Result = then_error(pe_expected("`within` and a duration "
                    ++ "after the `then` pattern", peek(T2)), peek_pos(T2, Pos))
            )
        )
    else
        Result = then_error(pe_expected("`then`", peek(Toks)), Pos)
    ).

    %@helper
:- pred finish_then_line(list(lgra_8_5_2_then_step)::in, list(positioned)::in,
                         then_line_result::out) is det.

finish_then_line(Steps, Toks, Result) :-
    ( if end_of_clause(Toks, Rest) then
        Result = then_ok(Steps, Rest)
    else
        Result = then_error(pe_expected("the end of the `then` pattern",
            peek(Toks)), peek_pos(Toks, pos(1, 0)))
    ).

    %@helper
:- pred finish_sequence(sequence_latest::in, lgra_8_1_pattern_body::in,
                        list(lgra_8_5_2_then_step)::in, pos::in,
                        list(positioned)::in, pattern_result::out) is det.

finish_sequence(Latest, Head, Steps, Pos, Toks, Result) :-
    ( if end_of_clause(Toks, Rest) then
        Result = pat_ok(pat_sequence(Latest, Head, Steps, Pos), Rest)
    else
        Result = pat_error(pe_expected("the end of the sequence pattern",
            peek(Toks)), peek_pos(Toks, pos(1, 0)))
    ).

    %@helper
:- pred last_step_has_where(list(lgra_8_5_2_then_step)::in) is semidet.

last_step_has_where([S | Ss]) :-
    (
        Ss = [],
        S ^ ts_body ^ pb_where = yes(_)
    ;
        Ss = [_ | _],
        last_step_has_where(Ss)
    ).

    %@helper
:- func set_last_step_where(lgra_9_3_1_expr, maybe(lreg_4_1_capture),
                            list(lgra_8_5_2_then_step))
    = list(lgra_8_5_2_then_step).

set_last_step_where(_, _, []) = [].
set_last_step_where(E, Cap, [S | Ss]) =
    ( if Ss = [] then
        [(S ^ ts_body ^ pb_where := yes(E)) ^ ts_body ^ pb_capture := Cap]
    else
        [S | set_last_step_where(E, Cap, Ss)]
    ).

    % `Acc` is reversed, so the clause above is its head. With a `no` or nothing
    % above, the steps become `lc_then` clauses for [LTHE.4.8] and [LTHE.4.9].
    %
    %@helper
:- func fold_then_line(list(lgra_8_5_2_then_step), list(lgra_8_1_lhs_clause))
    = list(lgra_8_1_lhs_clause).

fold_then_line(Steps, Acc) = Folded :-
    ( if Acc = [lc_pattern(pat_simple(Head)) | Rest] then
        Folded = [lc_pattern(pat_sequence(sl_plain, Head, Steps,
            Head ^ pb_pos)) | Rest]
    else if Acc = [lc_pattern(pat_sequence(L, Head, Steps0, P)) | Rest] then
        Folded = [lc_pattern(pat_sequence(L, Head, Steps0 ++ Steps, P))
            | Rest]
    else
        Folded = list.foldl((func(S, A) = [lc_then(S) | A]), Steps, Acc)
    ).

    %@helper
:- type body_result
    --->    body_ok(lgra_8_1_pattern_body, list(positioned))
    ;       body_error(parse_error, pos).

    %@spec [LGRA.8.1]
    %@spec [LGRA.8.3.3]
    %@spec [LGRA.8.6]
:- pred lgra_8_1_parse_body(list(positioned)::in, body_result::out) is det.

lgra_8_1_parse_body(Toks, Result) :-
    lgra_8_1_parse_body_mode(Toks, within_here, Result).

    % Whether a `within` after this body is the body's or its `then` step's.
    %
    %@helper
:- type within_mode
    --->    within_here
    ;       within_is_the_steps.

    %@helper
:- pred lgra_8_1_parse_body_mode(list(positioned)::in, within_mode::in,
                                 body_result::out) is det.

lgra_8_1_parse_body_mode(Toks, WithinMode, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if lgra_8_1_take_type_ref(Toks, TypeRef, T1) then
        ( if take_name(T1, B, T2), not pattern_keyword(B ^ id_name) then
            Binding = yes(B),
            T3 = T2
        else
            Binding = no,
            T3 = T1
        ),
        ( if WithinMode = within_here, take_kw("within", T3, T4) then
            take_span_to(T4, [name("where"), name("then")], [], WSpan, T5),
            (
                WSpan = [],
                Result = body_error(pe_expected("a duration after `within`",
                    peek(T4)), peek_pos(T4, Pos))
            ;
                WSpan = [_ | _],
                ( if lgra_2_8_1_time_expr(WSpan) then
                    lgra_8_3_4_take_where(T5, Where, T6),
                    finish_body(TypeRef, Binding, yes(WSpan), Where, Pos, T6,
                        Result)
                else
                    Result = body_error(time_expr_error("within", WSpan),
                        peek_pos(WSpan, Pos))
                )
            )
        else
            lgra_8_3_4_take_where(T3, Where, T6),
            finish_body(TypeRef, Binding, no, Where, Pos, T6, Result)
        )
    else
        Result = body_error(pe_expected("a schema name", peek(Toks)), Pos)
    ).

    %@helper
:- pred finish_body(lgra_8_1_type_ref::in, maybe(ident)::in,
                    maybe(list(positioned))::in, where_result::in, pos::in,
                    list(positioned)::in, body_result::out) is det.

finish_body(TypeRef, Binding, Within, Where, Pos, Rest, Result) :-
    (
        Where = where_none,
        Result = body_ok(lgra_8_1_pattern_body(TypeRef, Binding, Within, no,
            no, Pos), Rest)
    ;
        Where = where_yes(E),
        Result = body_ok(lgra_8_1_pattern_body(TypeRef, Binding, Within,
            yes(E), no, Pos), Rest)
    ;
        Where = where_capture(E, Cap),
        Result = body_ok(lgra_8_1_pattern_body(TypeRef, Binding, Within,
            yes(E), yes(Cap), Pos), Rest)
    ;
        Where = where_missing(WP),
        Result = body_error(pe_expected("an expression after `where`",
            dedent), WP)
    ;
        Where = where_bad(Err, EP),
        Result = body_error(Err, EP)
    ).

    %@helper
:- pred pattern_keyword(string::in) is semidet.

pattern_keyword("where").
pattern_keyword("within").
pattern_keyword("then").

    % The span first: where a `where` ends may be a `)` of an enclosing `no (...)`.
    %
    %@spec [LGRA.8.3.4]
    %@spec [LGRA.8.3.5]
:- pred lgra_8_3_4_take_where(list(positioned)::in, where_result::out,
                   list(positioned)::out) is det.

lgra_8_3_4_take_where(Toks, Where, Rest) :-
    ( if take_kw("where", Toks, T1) then
        take_where_span(T1, 0, [], Span0, T2),
        Pos = peek_pos(T1, pos(1, 0)),
        ( if Span0 = [] then
            Where = where_missing(Pos),
            Rest = T2
        else
            ( if lreg_4_1_take_capture_names(Span0, Names, Span1) then
                MaybeNames = yes(Names),
                Span = Span1
            else
                MaybeNames = no,
                Span = Span0
            ),
            ( if Span = [] then
                Where = where_missing(Pos)
            else
                lgra_9_1_parse_expr(Span, ExprRes),
                (
                    ExprRes = ex_error(Err, EP),
                    Where = where_bad(Err, EP)
                ;
                    ExprRes = ex_ok(E, _),
                    (
                        MaybeNames = no,
                        Where = where_yes(E)
                    ;
                        MaybeNames = yes(Ns),
                        Where = where_capture(E,
                            lreg_4_1_capture(Ns, leftmost_conjunct(E), Pos))
                    )
                )
            ),
            Rest = T2
        )
    else
        Where = where_none,
        Rest = Toks
    ).

    % A single `=` after the `)` makes a capture list: `where (a) == b` is a
    % parenthesised expression.
    %
    %@spec [LGRA.8.1]
    %@spec [LREG.4.1]
    %@spec [LREG.4.3]
:- pred lreg_4_1_take_capture_names(list(positioned)::in, list(ident)::out,
                                    list(positioned)::out) is semidet.

lreg_4_1_take_capture_names(Toks, Names, Rest) :-
    take_tok(lparen, Toks, T1),
    take_capture_names(T1, [], Names, T2),
    Names = [_ | _],
    take_tok(rparen, T2, T3),
    take_tok(assign, T3, Rest).

    % The first operand of a left-nested `and` chain: `m and a and b` parses as
    % `(m and a) and b`, and `m` is what the capture list destructures.
    %
    %@helper
:- func leftmost_conjunct(lgra_9_3_1_expr) = lgra_9_3_1_expr.

leftmost_conjunct(E) =
    ( if E = ex_binary(bo_and, L, _, _) then leftmost_conjunct(L) else E ).

    %@helper
:- type where_result
    --->    where_none
    ;       where_yes(lgra_9_3_1_expr)
    ;       where_capture(lgra_9_3_1_expr, lreg_4_1_capture)
            % The whole condition, and [LREG.4.1]'s capture list over it.
    ;       where_missing(pos)
            % The bare keyword.
    ;       where_bad(parse_error, pos).

    % A `where` expression's tokens, to the NEWLINE that ends the clause or to
    % a closing bracket that this expression did not open: `no (P where Q)`.
    %
    %@helper
:- pred take_where_span(list(positioned)::in, int::in, list(positioned)::in,
                        list(positioned)::out, list(positioned)::out) is det.

take_where_span([], _, Acc, reverse(Acc), []).
take_where_span([P | Ps], Depth, Acc, Span, Rest) :-
    Tok = P ^ tk_tok,
    ( if Tok = newline then
        Span = reverse(Acc),
        Rest = [P | Ps]
    else if llex_7_5_3_bracket_open(Tok, _) then
        take_where_span(Ps, Depth + 1, [P | Acc], Span, Rest)
    else if llex_7_5_3_bracket_close(Tok) then
        ( if Depth =< 0 then
            Span = reverse(Acc),
            Rest = [P | Ps]
        else
            take_where_span(Ps, Depth - 1, [P | Acc], Span, Rest)
        )
    else
        take_where_span(Ps, Depth, [P | Acc], Span, Rest)
    ).

    % The last name is the schema and the rest the library path ([LGRA.22.4]).
    %
    %@spec [LGRA.8.1]
    %@spec [LGRA.22.4]
:- pred lgra_8_1_take_type_ref(list(positioned)::in, lgra_8_1_type_ref::out,
                               list(positioned)::out) is semidet.

lgra_8_1_take_type_ref(Toks, TypeRef, Rest) :-
    take_name(Toks, First, T1),
    not pattern_keyword(First ^ id_name),
    take_dot_names(T1, [], Tail, T2),
    ( if list.split_last([First | Tail], Path, N), Path = [_ | _] then
        TypeRef = tr_qualified(Path, N)
    else
        TypeRef = tr_bare(First)
    ),
    Rest = T2.

    %@helper
:- pred take_dot_names(list(positioned)::in, list(ident)::in,
                       list(ident)::out, list(positioned)::out) is det.

take_dot_names(Toks, Acc, Names, Rest) :-
    ( if take_tok(dot, Toks, T1), take_name(T1, N, T2) then
        take_dot_names(T2, [N | Acc], Names, Rest)
    else
        Names = reverse(Acc),
        Rest = Toks
    ).

    % A NEWLINE, or the end of a file with no trailing newline.
    %
    %@helper
:- pred end_of_clause(list(positioned)::in, list(positioned)::out) is semidet.

end_of_clause(Toks, Rest) :-
    ( if take_tok(newline, Toks, T) then
        Rest = T
    else
        Toks = [],
        Rest = []
    ).

%-----------------------------------------------------------------------------%
% Expressions -- [LGRA.9.3.1] through [LGRA.9.7.1]
%-----------------------------------------------------------------------------%
%
% One predicate per precedence level, in the clauses' order.

lgra_9_1_parse_expr(Span, Result) :-
    lgra_9_3_1_or(Span, Res0),
    (
        Res0 = ex_error(_, _),
        Result = Res0
    ;
        Res0 = ex_ok(E, Rest),
        (
            Rest = [],
            Result = ex_ok(E, [])
        ;
            Rest = [P | _],
            Result = ex_error(pe_expected("the end of the expression",
                P ^ tk_tok), P ^ tk_pos)
        )
    ).

    %@spec [LGRA.9.3.1]
    %@spec [LGRA.2.11.1]
:- pred lgra_9_3_1_or(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_or(Toks, Result) :-
    lgra_9_3_1_and(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        or_tail(E, Rest, Result)
    ).

    %@helper
:- pred or_tail(lgra_9_3_1_expr::in, list(positioned)::in, expr_result::out)
    is det.

or_tail(Acc, Toks, Result) :-
    ( if Toks = [P | _], take_kw("or", Toks, T1) then
        lgra_9_3_1_and(T1, Right),
        (
            Right = ex_error(_, _),
            Result = Right
        ;
            Right = ex_ok(R, Rest),
            or_tail(ex_binary(bo_or, Acc, R, P ^ tk_pos), Rest, Result)
        )
    else
        Result = ex_ok(Acc, Toks)
    ).

    %@spec [LGRA.9.3.1]
:- pred lgra_9_3_1_and(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_and(Toks, Result) :-
    lgra_9_3_1_not(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        and_tail(E, Rest, Result)
    ).

    %@helper
:- pred and_tail(lgra_9_3_1_expr::in, list(positioned)::in, expr_result::out)
    is det.

and_tail(Acc, Toks, Result) :-
    ( if Toks = [P | _], take_kw("and", Toks, T1) then
        lgra_9_3_1_not(T1, Right),
        (
            Right = ex_error(_, _),
            Result = Right
        ;
            Right = ex_ok(R, Rest),
            and_tail(ex_binary(bo_and, Acc, R, P ^ tk_pos), Rest, Result)
        )
    else
        Result = ex_ok(Acc, Toks)
    ).

    %@spec [LGRA.9.3.1]
    %@spec [LGRA.2.11.5]
:- pred lgra_9_3_1_not(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_not(Toks, Result) :-
    ( if Toks = [P | _], take_kw("not", Toks, T1) then
        lgra_9_3_1_not(T1, Inner),
        (
            Inner = ex_error(_, _),
            Result = Inner
        ;
            Inner = ex_ok(E, Rest),
            Result = ex_ok(ex_not(E, P ^ tk_pos), Rest)
        )
    else
        lgra_9_3_1_comparison(Toks, Result)
    ).

    % The chain is kept as a chain: `a < b < c` is a desugaring, not
    % associativity ([LGRA.9.3.2]).
    %
    %@spec [LGRA.9.3.1]
    %@spec [LGRA.9.3.2]
:- pred lgra_9_3_1_comparison(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_comparison(Toks, Result) :-
    lgra_9_3_1_coalesce(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        ( if Rest = [P | _], take_kw("is", Rest, T1) then
            ( if take_kw("not", T1, T2) then
                Neg = is_negated,
                T3 = T2
            else
                Neg = is_positive,
                T3 = T1
            ),
            ( if lgra_9_3_3_take_is_subject(T3, Subject, T4) then
                Result = ex_ok(ex_is(E, Neg, Subject, P ^ tk_pos), T4)
            else
                Result = ex_error(pe_expected("`null`, `true`, `false`, "
                    ++ "`inf`, `-inf`, `NaN`, or one of `Int` `Float` `Bool` "
                    ++ "`String` `Bytes` `Json` after `is`", peek(T3)),
                    peek_pos(T3, P ^ tk_pos))
            )
        else
            compare_tail(E, Rest, [], Result)
        )
    ).

    %@helper
:- pred compare_tail(lgra_9_3_1_expr::in, list(positioned)::in,
                     list(lgra_9_3_2_compare_step)::in, expr_result::out)
    is det.

compare_tail(Head, Toks, Acc, Result) :-
    ( if Toks = [P | _], lgra_9_3_1_compare_op(P ^ tk_tok, Op), take_tok(P ^ tk_tok,
            Toks, T1) then
        lgra_9_3_1_coalesce(T1, Right),
        (
            Right = ex_error(_, _),
            Result = Right
        ;
            Right = ex_ok(R, Rest),
            Step = lgra_9_3_2_compare_step(Op, R, P ^ tk_pos),
            compare_tail(Head, Rest, [Step | Acc], Result)
        )
    else
        (
            Acc = [],
            Result = ex_ok(Head, Toks)
        ;
            Acc = [S | _],
            Result = ex_ok(ex_compare(Head, reverse(Acc), S ^ cs_pos), Toks)
        )
    ).

    %@spec [LGRA.9.3.1]
:- pred lgra_9_3_1_compare_op(token::in, lgra_9_3_2_compare_op::out) is semidet.

lgra_9_3_1_compare_op(eq, co_eq).
lgra_9_3_1_compare_op(ne, co_ne).
lgra_9_3_1_compare_op(lt, co_lt).
lgra_9_3_1_compare_op(le, co_le).
lgra_9_3_1_compare_op(gt, co_gt).
lgra_9_3_1_compare_op(ge, co_ge).

    % The tag names are not the type namespace: `Time` and a schema name are no
    % subjects.
    %
    %@spec [LGRA.9.3.3]
:- pred lgra_9_3_3_take_is_subject(list(positioned)::in, is_subject::out,
                                   list(positioned)::out) is semidet.

lgra_9_3_3_take_is_subject(Toks, Subject, Rest) :-
    ( if take_tok(minus, Toks, TM), take_kw("inf", TM, TR) then
        Subject = is_inf(inf_negative),
        Rest = TR
    else
        take_name(Toks, Id, T1),
        Rest = T1,
        Name = Id ^ id_name,
        ( if Name = "null" then Subject = is_null
        else if Name = "true" then Subject = is_bool(yes)
        else if Name = "false" then Subject = is_bool(no)
        else if Name = "inf" then Subject = is_inf(inf_positive)
        else if Name = "NaN" then Subject = is_nan
        else lgra_9_3_3_tag_name(Name), Subject = is_tag(Id)
        )
    ).

    %@helper
:- pred lgra_9_3_3_tag_name(string::in) is semidet.

lgra_9_3_3_tag_name("Int").
lgra_9_3_3_tag_name("Float").
lgra_9_3_3_tag_name("Bool").
lgra_9_3_3_tag_name("String").
lgra_9_3_3_tag_name("Bytes").
lgra_9_3_3_tag_name("Json").

    %@helper
:- pred lgra_9_3_1_coalesce(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_coalesce(Toks, Result) :-
    lreg_1_1_match(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        coalesce_tail(E, Rest, Result)
    ).

    %@helper
:- pred coalesce_tail(lgra_9_3_1_expr::in, list(positioned)::in,
                      expr_result::out) is det.

coalesce_tail(Acc, Toks, Result) :-
    ( if Toks = [P | _], take_tok(question2, Toks, T1) then
        lreg_1_1_match(T1, Right),
        (
            Right = ex_error(_, _),
            Result = Right
        ;
            Right = ex_ok(R, Rest),
            coalesce_tail(ex_binary(bo_coalesce, Acc, R, P ^ tk_pos), Rest,
                Result)
        )
    else
        Result = ex_ok(Acc, Toks)
    ).

    % Not a loop, and the right operand is a token: the lexer turns a `/` after
    % `~` into a whole `regex_lit` ([LREG.5.5]).
    %
    %@spec [LREG.1.1]
    %@spec [LREG.1.3]
    %@spec [LREG.1.4]
    %@spec [LREG.5.5]
    %@spec [LREG.10.7]
:- pred lreg_1_1_match(list(positioned)::in, expr_result::out) is det.

lreg_1_1_match(Toks, Result) :-
    lgra_9_3_1_interval_rel(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        ( if
            Rest = [P | T1],
            Op = P ^ tk_tok,
            ( Op = match_op, Sense = ms_match
            ; Op = nmatch_op, Sense = ms_not_match
            )
        then
            ( if T1 = [R | T2], R ^ tk_tok = regex_lit(Pattern, Flags) then
                Result = ex_ok(ex_match(E, Sense, Pattern, Flags, P ^ tk_pos),
                    T2)
            else
                Result = ex_error(pe_expected("a regex literal `/pattern/` "
                    ++ "after " ++ describe(Op) ++ " ([LREG.5.5])", peek(T1)),
                    peek_pos(T1, P ^ tk_pos))
            )
        else
            Result = ex_ok(E, Rest)
        )
    ).

    %@helper
:- pred lgra_9_3_1_interval_rel(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_interval_rel(Toks, Result) :-
    lgra_9_3_1_interval(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        ( if
            Rest = [P | _],
            P ^ tk_tok = name(Kw),
            interval_rel_op(Kw, Op),
            take_kw(Kw, Rest, T1)
        then
            lgra_9_3_1_interval(T1, Right),
            (
                Right = ex_error(_, _),
                Result = Right
            ;
                Right = ex_ok(R, Rest2),
                Result = ex_ok(ex_binary(Op, E, R, P ^ tk_pos), Rest2)
            )
        else
            Result = ex_ok(E, Rest)
        )
    ).

    %@helper
:- pred interval_rel_op(string::in, lgra_9_3_1_binary_op::out) is semidet.

interval_rel_op("in", bo_in).
interval_rel_op("contains", bo_contains).
interval_rel_op("overlaps", bo_overlaps).

    %@helper
:- pred lgra_9_3_1_interval(list(positioned)::in, expr_result::out) is det.

lgra_9_3_1_interval(Toks, Result) :-
    lgra_9_4_1_bitor(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        ( if Rest = [P | _], take_tok(dotdot, Rest, T1) then
            lgra_9_4_1_bitor(T1, Right),
            (
                Right = ex_error(_, _),
                Result = Right
            ;
                Right = ex_ok(R, Rest2),
                Result = ex_ok(ex_binary(bo_interval, E, R, P ^ tk_pos),
                    Rest2)
            )
        else
            Result = ex_ok(E, Rest)
        )
    ).

    %@spec [LGRA.9.4.1]
:- pred lgra_9_4_1_bitor(list(positioned)::in, expr_result::out) is det.

lgra_9_4_1_bitor(Toks, Result) :-
    lgra_9_4_1_bitxor(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest, [pipe - bo_bitor], bitxor_level, Result)
    ).

    %@helper
:- pred lgra_9_4_1_bitxor(list(positioned)::in, expr_result::out) is det.

lgra_9_4_1_bitxor(Toks, Result) :-
    lgra_9_4_1_bitand(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest, [caret - bo_bitxor], bitand_level, Result)
    ).

    %@helper
:- pred lgra_9_4_1_bitand(list(positioned)::in, expr_result::out) is det.

lgra_9_4_1_bitand(Toks, Left0) :-
    lgra_9_4_1_shift(Toks, Left),
    (
        Left = ex_error(_, _),
        Left0 = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest, [amp - bo_bitand], shift_level, Left0)
    ).

    %@helper
:- pred lgra_9_4_1_shift(list(positioned)::in, expr_result::out) is det.

lgra_9_4_1_shift(Toks, Result) :-
    lgra_9_5_1_additive(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest, [shl - bo_shl, shr - bo_shr], additive_level,
            Result)
    ).

    %@spec [LGRA.9.5.1]
:- pred lgra_9_5_1_additive(list(positioned)::in, expr_result::out) is det.

lgra_9_5_1_additive(Toks, Result) :-
    lgra_9_5_1_multiplicative(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest, [plus - bo_add, minus - bo_sub],
            multiplicative_level, Result)
    ).

    %@spec [LGRA.9.5.1]
:- pred lgra_9_5_1_multiplicative(list(positioned)::in, expr_result::out)
    is det.

lgra_9_5_1_multiplicative(Toks, Result) :-
    lgra_9_5_1_exponent(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        binary_tail(E, Rest,
            [star - bo_mul, slash - bo_div, slash2 - bo_floordiv,
             percent - bo_mod], exponent_level, Result)
    ).

    % Right-associative.
    %
    %@spec [LGRA.9.5.1]
:- pred lgra_9_5_1_exponent(list(positioned)::in, expr_result::out) is det.

lgra_9_5_1_exponent(Toks, Result) :-
    lgra_9_5_1_unary(Toks, Left),
    (
        Left = ex_error(_, _),
        Result = Left
    ;
        Left = ex_ok(E, Rest),
        ( if Rest = [P | _], take_tok(star2, Rest, T1) then
            lgra_9_5_1_exponent(T1, Right),
            (
                Right = ex_error(_, _),
                Result = Right
            ;
                Right = ex_ok(R, Rest2),
                Result = ex_ok(ex_binary(bo_pow, E, R, P ^ tk_pos), Rest2)
            )
        else
            Result = ex_ok(E, Rest)
        )
    ).

    %@spec [LGRA.9.5.1]
:- pred lgra_9_5_1_unary(list(positioned)::in, expr_result::out) is det.

lgra_9_5_1_unary(Toks, Result) :-
    ( if
        Toks = [Minus, Magnitude | AfterMin],
        Minus ^ tk_tok = minus,
        Magnitude ^ tk_tok = int_min_magnitude
    then
        % The only way to write INT64_MIN ([LGRA.2.7.3]).
        Result = ex_ok(ex_int(int64.min_int64, Minus ^ tk_pos), AfterMin)
    else if Toks = [P | _], lgra_9_5_1_unary_op_of(P ^ tk_tok, Op), take_tok(P ^ tk_tok, Toks,
            T1) then
        lgra_9_5_1_unary(T1, Inner),
        (
            Inner = ex_error(_, _),
            Result = Inner
        ;
            Inner = ex_ok(E, Rest),
            Result = ex_ok(ex_unary(Op, E, P ^ tk_pos), Rest)
        )
    else
        lgra_9_6_1_postfix(Toks, Result)
    ).

    %@spec [LGRA.9.5.1]
:- pred lgra_9_5_1_unary_op_of(token::in, lgra_9_5_1_unary_op::out) is semidet.

lgra_9_5_1_unary_op_of(minus, uo_neg).
lgra_9_5_1_unary_op_of(plus, uo_pos).
lgra_9_5_1_unary_op_of(tilde, uo_bitnot).
    % `~` arrives as `match_op` ([LLEX.8.3.1]): in prefix position it is bitwise
    % not, and after an operand `lreg_1_1_match` takes it.
lgra_9_5_1_unary_op_of(match_op, uo_bitnot).

    %@spec [LGRA.9.6.1]
    %@spec [LGRA.7.11.1]
:- pred lgra_9_6_1_postfix(list(positioned)::in, expr_result::out) is det.

lgra_9_6_1_postfix(Toks, Result) :-
    lgra_9_7_1_primary(Toks, Prim),
    (
        Prim = ex_error(_, _),
        Result = Prim
    ;
        Prim = ex_ok(E, Rest),
        lcst_4_1_1_postfix_tail(E, Rest, Result)
    ).

    % The cast is a suffix here, not a precedence level ([LCST.4.1.1],
    % [LCST.4.1.4]). Its `?` is taken before any operator: `x::Int??d` is a total
    % cast then a coalesce, since `??` is one token ([LCST.4.1.3]).
    %
    %@spec [LCST.4.1.1]
    %@spec [LCST.4.1.3]
    %@spec [LCST.4.1.4]
:- pred lcst_4_1_1_postfix_tail(lgra_9_3_1_expr::in, list(positioned)::in,
                     expr_result::out) is det.

lcst_4_1_1_postfix_tail(Acc, Toks, Result) :-
    ( if Toks = [P | _], take_tok(dot, Toks, T1), take_name(T1, N, T2) then
        lcst_4_1_1_postfix_tail(ex_slot(Acc, N, P ^ tk_pos), T2, Result)
    else if Toks = [P | _], take_tok(lbracket, Toks, T1) then
        lgra_9_3_1_or(T1, Ix),
        (
            Ix = ex_error(_, _),
            Result = Ix
        ;
            Ix = ex_ok(IxE, T2),
            ( if take_tok(rbracket, T2, T3) then
                lcst_4_1_1_postfix_tail(ex_index(Acc, IxE, P ^ tk_pos), T3, Result)
            else
                Result = ex_error(pe_expected("`]` closing the index",
                    peek(T2)), peek_pos(T2, P ^ tk_pos))
            )
        )
    else if Toks = [P | _], take_tok(lparen, Toks, T1) then
        lgra_9_6_1_arguments(T1, [], Args),
        (
            Args = args_error(Err, EP),
            Result = ex_error(Err, EP)
        ;
            Args = args_ok(As, T2),
            lcst_4_1_1_postfix_tail(ex_call(Acc, As, P ^ tk_pos), T2, Result)
        )
    else if
        Toks = [P | _],
        take_tok(coloncolon, Toks, T1),
        llex_10_8_3_take_type(T1, Ty, T2)
    then
        ( if take_tok(question, T2, T3) then
            Null = nullable,
            T4 = T3
        else
            Null = non_null,
            T4 = T2
        ),
        lcst_4_1_1_postfix_tail(ex_cast(Acc, Ty, Null, P ^ tk_pos), T4, Result)
    else
        Result = ex_ok(Acc, Toks)
    ).

    %@helper
:- type args_result
    --->    args_ok(list(lgra_9_3_1_expr), list(positioned))
    ;       args_error(parse_error, pos).

    %@spec [LGRA.9.6.1]
:- pred lgra_9_6_1_arguments(list(positioned)::in, list(lgra_9_3_1_expr)::in,
                        args_result::out) is det.

lgra_9_6_1_arguments(Toks, Acc, Result) :-
    ( if Acc = [], take_tok(rparen, Toks, T1) then
        Result = args_ok([], T1)
    else
        lgra_9_3_1_or(Toks, Arg),
        (
            Arg = ex_error(Err, EP),
            Result = args_error(Err, EP)
        ;
            Arg = ex_ok(E, T1),
            ( if take_tok(comma, T1, T2) then
                lgra_9_6_1_arguments(T2, [E | Acc], Result)
            else if take_tok(rparen, T1, T2) then
                Result = args_ok(reverse([E | Acc]), T2)
            else
                Result = args_error(pe_expected("`,` or `)` in the argument "
                    ++ "list", peek(T1)), peek_pos(T1, pos(1, 0)))
            )
        )
    ).

    % `lib.CONST` is a `NAME` here and a `.` chain in `postfix`; what it denotes
    % is resolved by scope ([LGRA.22.9]).
    %
    %@spec [LGRA.9.7.1]
:- pred lgra_9_7_1_primary(list(positioned)::in, expr_result::out) is det.

lgra_9_7_1_primary(Toks, Result) :-
    ( if Toks = [P | Ps] then
        Pos = P ^ tk_pos,
        Tok = P ^ tk_tok,
        ( if Tok = int_lit(I) then
            Result = ex_ok(ex_int(I, Pos), Ps)
        else if Tok = int_min_magnitude then
            Result = ex_error(pe_expected("an integer literal within the "
                ++ "64-bit range; 9223372036854775808 is in range only as "
                ++ "`-9223372036854775808` ([LGRA.2.7.3])", Tok), Pos)
        else if Tok = float_lit(F) then
            Result = ex_ok(ex_float(F, Pos), Ps)
        else if Tok = single_str(S) then
            Result = ex_ok(ex_string(S, Pos), Ps)
        else if Tok = triple_str(S) then
            Result = ex_ok(ex_string(S, Pos), Ps)
        else if Tok = unit_lit(Mag, Suffix) then
            Result = ex_ok(ex_unit(Mag, Suffix, Pos), Ps)
        else if Tok = name("true") then
            Result = ex_ok(ex_bool(yes, Pos), Ps)
        else if Tok = name("false") then
            Result = ex_ok(ex_bool(no, Pos), Ps)
        else if Tok = name("null") then
            Result = ex_ok(ex_null(Pos), Ps)
        else if Tok = name(N) then
            Result = ex_ok(ex_name(ident(N, Pos)), Ps)
        else if Tok = lparen then
            lgra_9_3_1_or(Ps, Inner),
            (
                Inner = ex_error(_, _),
                Result = Inner
            ;
                Inner = ex_ok(E, T1),
                ( if take_tok(rparen, T1, T2) then
                    Result = ex_ok(E, T2)
                else
                    Result = ex_error(pe_expected("`)` closing the "
                        ++ "expression", peek(T1)), peek_pos(T1, Pos))
                )
            )
        else
            Result = ex_error(pe_expected("an expression", Tok), Pos)
        )
    else
        Result = ex_error(pe_expected("an expression", dedent), pos(1, 0))
    ).

    % The next level down, for the left-associative loop in `binary_tail`.
    %
    %@helper
:- type expr_level
    --->    bitxor_level
    ;       bitand_level
    ;       shift_level
    ;       additive_level
    ;       multiplicative_level
    ;       exponent_level.

    %@helper
:- pred parse_level(expr_level::in, list(positioned)::in, expr_result::out)
    is det.

parse_level(bitxor_level, Toks, R) :- lgra_9_4_1_bitxor(Toks, R).
parse_level(bitand_level, Toks, R) :- lgra_9_4_1_bitand(Toks, R).
parse_level(shift_level, Toks, R) :- lgra_9_4_1_shift(Toks, R).
parse_level(additive_level, Toks, R) :- lgra_9_5_1_additive(Toks, R).
parse_level(multiplicative_level, Toks, R) :-
    lgra_9_5_1_multiplicative(Toks, R).
parse_level(exponent_level, Toks, R) :- lgra_9_5_1_exponent(Toks, R).

    %@helper
:- pred binary_tail(lgra_9_3_1_expr::in, list(positioned)::in,
                    assoc_list(token, lgra_9_3_1_binary_op)::in,
                    expr_level::in, expr_result::out) is det.

binary_tail(Acc, Toks, Ops, Level, Result) :-
    ( if
        Toks = [P | _],
        assoc_list.search(Ops, P ^ tk_tok, Op),
        take_tok(P ^ tk_tok, Toks, T1)
    then
        parse_level(Level, T1, Right),
        (
            Right = ex_error(_, _),
            Result = Right
        ;
            Right = ex_ok(R, Rest),
            binary_tail(ex_binary(Op, Acc, R, P ^ tk_pos), Rest, Ops, Level,
                Result)
        )
    else
        Result = ex_ok(Acc, Toks)
    ).

%-----------------------------------------------------------------------------%
% Schemas -- [LGRA.5.1]
%-----------------------------------------------------------------------------%

    %@spec [LGRA.5.1]
:- pred lgra_5_1_parse_schema(list(positioned)::in, decl_result::out) is det.

lgra_5_1_parse_schema(Toks, Result) :-
    Pos = peek_pos(Toks, pos(1, 0)),
    ( if
        take_kw("schema", Toks, T1),
        take_name(T1, Name, T2)
    then
        lgra_5_2_parse_lifecycle(T2, LifeRes),
        (
            LifeRes = life_error(LErr, LEP),
            Result = td_error(LErr, LEP)
        ;
            LifeRes = life_ok(Lifecycle, T3),
            parse_schema_body(Name, Lifecycle, Pos, T3, Result)
        )
    else
        Result = td_error(pe_expected("a schema name", peek(Toks)), Pos)
    ).

    % The schema's `:`, docstring and fields, after its lifecycle.
    %
    %@helper
:- pred parse_schema_body(ident::in, maybe(lgra_5_2_lifecycle)::in,
    pos::in, list(positioned)::in, decl_result::out) is det.

parse_schema_body(Name, Lifecycle, Pos, T3, Result) :-
    ( if
        take_tok(colon, T3, T4),
        take_tok(newline, T4, T5),
        take_tok(indent, T5, T6)
    then
        lgra_5_6_parse_doc(T6, Doc, T7),
        parse_fields(T7, [], FieldsRes),
        (
            FieldsRes = fs_error(Err, EP),
            Result = td_error(Err, EP)
        ;
            FieldsRes = fs_ok(Fields, T8),
            (
                Fields = [],
                Result = td_error(pe_empty_schema(Name ^ id_name), Pos)
            ;
                Fields = [_ | _],
                ( if take_tok(dedent, T8, T9) then
                    Result = td_ok(td_schema(lgra_5_1_schema_decl(Name, Lifecycle,
                        Doc, Fields, Pos)), T9)
                else
                    Result = td_error(
                        pe_expected("end of the schema body", peek(T8)),
                        peek_pos(T8, Pos))
                )
            )
        )
    else
        Result = td_error(pe_expected("`:` and an indented body",
            peek(T3)), peek_pos(T3, Pos))
    ).

    %@helper
:- type lifecycle_result
    --->    life_ok(maybe(lgra_5_2_lifecycle), list(positioned))
    ;       life_error(parse_error, pos).

    % Absent is defaulted in `build` ([LSCP.1.4]).
    %
    %@spec [LGRA.5.2]
    %@spec [LSCP.1.5]
:- pred lgra_5_2_parse_lifecycle(list(positioned)::in, lifecycle_result::out)
    is det.

lgra_5_2_parse_lifecycle(Toks, Result) :-
    ( if take_kw("scope", Toks, T1) then
        ( if take_kw("explicit", T1, T2) then
            Result = life_ok(yes(lc_explicit), T2)
        else if take_kw("activation", T1, T2) then
            Result = life_ok(yes(lc_activation), T2)
        else if take_kw("logical", T1, T2) then
            parse_ambient(T2, Amb, T3),
            Result = life_ok(yes(lc_logical(Amb)), T3)
        else if take_kw("ttl", T1, T2) then
            lgra_2_8_10_parse_ttl(T2, peek_pos(T1, pos(1, 0)),
                (func(L) = L), Result)
        else if take_kw("ambient", T1, T2) then
            % For `dsc.validate`'s refusal ([LSCP.1.7]).
            Result = life_ok(yes(lc_bare_ambient), T2)
        else
            % The caller's `:` check fails and names the right thing.
            Result = life_ok(no, Toks)
        )
    else if take_kw("logical", Toks, T1) then
        % The unprefixed forms, for `dsc.validate`'s refusal ([LSCP.1.6]).
        parse_ambient(T1, Amb, T2),
        Result = life_ok(yes(lc_unprefixed(lc_logical(Amb))), T2)
    else if take_kw("ttl", Toks, T1) then
        lgra_2_8_10_parse_ttl(T1, peek_pos(Toks, pos(1, 0)),
            (func(L) = lc_unprefixed(L)), Result)
    else
        Result = life_ok(no, Toks)
    ).

    % `ttl <time_expr> ambient?` up to the `:`. The span is one `UNIT_LIT` or one
    % `NAME`, so a sign, an operator or a missing duration is refused here, at
    % the span's first token, or at the `:` when there is none. `KwPos` is the
    % `ttl`'s.
    %
    %@spec [LGRA.2.8.10]
:- pred lgra_2_8_10_parse_ttl(list(positioned)::in, pos::in,
    (func(lgra_5_2_lifecycle) = lgra_5_2_lifecycle)::in, lifecycle_result::out)
    is det.

lgra_2_8_10_parse_ttl(Toks, KwPos, Wrap, Result) :-
    take_span_to(Toks, [colon], [], Span, Rest),
    parse_ambient_span(Span, Amb, Kept),
    ( if lgra_2_8_1_time_expr(Kept) then
        Result = life_ok(yes(Wrap(lc_ttl(Kept, Amb))), Rest)
    else
        Shown = Kept ++ Rest,
        Result = life_error(time_expr_error("ttl", Shown),
            peek_pos(Shown, KwPos))
    ).

    %@helper
:- pred parse_ambient(list(positioned)::in, ambient::out,
                      list(positioned)::out) is det.

parse_ambient(Toks, Amb, Rest) :-
    ( if take_kw("ambient", Toks, T1) then
        Amb = ambient,
        Rest = T1
    else
        Amb = not_ambient,
        Rest = Toks
    ).

    % The trailing `ambient` of `ttl <time_expr> ambient?` comes off the span.
    %
    %@helper
:- pred parse_ambient_span(list(positioned)::in, ambient::out,
                           list(positioned)::out) is det.

parse_ambient_span(Span, Amb, Kept) :-
    ( if
        Span = [_ | _],
        Last = det_last(Span),
        Last ^ tk_tok = name("ambient")
    then
        Amb = ambient,
        Kept = take_upto(length(Span) - 1, Span)
    else
        Amb = not_ambient,
        Kept = Span
    ).

    %@helper
:- pred take_span_to(list(positioned)::in, list(token)::in,
                     list(positioned)::in, list(positioned)::out,
                     list(positioned)::out) is det.

take_span_to([], _, Acc, reverse(Acc), []).
take_span_to([P | Ps], Stops, Acc, Span, Rest) :-
    ( if ( member(P ^ tk_tok, Stops) ; P ^ tk_tok = newline ) then
        Span = reverse(Acc),
        Rest = [P | Ps]
    else
        take_span_to(Ps, Stops, [P | Acc], Span, Rest)
    ).

    % A shape check over a collected span. A NAME's type is the validator's.
    %
    %@spec [LGRA.2.8.1]
    %@spec [LGRA.2.8.2]
    %@spec [LGRA.2.8.10]
:- pred lgra_2_8_1_time_expr(list(positioned)::in) is semidet.

lgra_2_8_1_time_expr([P]) :-
    ( P ^ tk_tok = unit_lit(_, _)
    ; P ^ tk_tok = name(_)
    ).

    %@helper
:- func time_expr_error(string, list(positioned)) = parse_error.

time_expr_error(Kw, Span) = pe_expected(
    "a duration after `" ++ Kw ++ "` -- a unit literal like `30_s` or a "
        ++ "name bound to one, with no sign and no operators ([LGRA.2.8.1])",
    peek(Span)).

    %@spec [LGRA.5.6]
    %@spec [LGRA.6.5]
:- pred lgra_5_6_parse_doc(list(positioned)::in, maybe(string)::out,
                  list(positioned)::out) is det.

lgra_5_6_parse_doc(Toks, Result, Rest) :-
    ( if
        Toks = [P | T1],
        ( P ^ tk_tok = single_str(S) ; P ^ tk_tok = triple_str(S) ),
        take_tok(newline, T1, T2)
    then
        Result = yes(S),
        Rest = T2
    else
        Result = no,
        Rest = Toks
    ).

    %@helper
:- type fields_result
    --->    fs_ok(list(lgra_5_7_1_field_decl), list(positioned))
    ;       fs_error(parse_error, pos).

    %@helper
:- pred parse_fields(list(positioned)::in, list(lgra_5_7_1_field_decl)::in,
                     fields_result::out) is det.

parse_fields(Toks, Acc, Result) :-
    ( if lgra_5_7_1_parse_field(Toks, Field, Rest) then
        parse_fields(Rest, [Field | Acc], Result)
    else if luni_14_9_complex_unit(Toks, Unit, Pos) then
        Result = fs_error(pe_complex_unit(Unit), Pos)
    else
        Result = fs_ok(reverse(Acc), Toks)
    ).

    % `NAME ':' complex UNIT`, where the field production has just failed. A
    % schema named `complex` followed by a stray name lands here too.
    %
    %@spec [LUNI.14.9]
:- pred luni_14_9_complex_unit(list(positioned)::in, string::out, pos::out)
    is semidet.

luni_14_9_complex_unit(Toks, Unit, Pos) :-
    take_name(Toks, _, T1),
    take_tok(colon, T1, T2),
    llex_10_8_3_take_type(T2, Type, T3),
    Type ^ id_name = "complex",
    llex_10_8_3_take_type(T3, UnitId, _),
    not slot_marker_of(UnitId, _),
    Unit = UnitId ^ id_name,
    Pos = Type ^ id_pos.

    %@spec [LGRA.5.7.1]
:- pred lgra_5_7_1_parse_field(list(positioned)::in, lgra_5_7_1_field_decl::out,
                    list(positioned)::out) is semidet.

lgra_5_7_1_parse_field(Toks, Field, Rest) :-
    take_name(Toks, Name, T1),
    take_tok(colon, T1, T2),
    llex_10_8_3_take_type(T2, Type, T3),
    ( if take_tok(question, T3, T4a) then
        Null = nullable,
        T4 = T4a
    else
        Null = non_null,
        T4 = T3
    ),
    lstr_11_1_take_capacity(T4, Cap, T4b),
    take_markers(T4b, [], Markers, T5),
    lgra_5_1_take_tolerance(T5, Tol, T6),
    take_field_doc(T6, Doc, T7),
    take_tok(newline, T7, Rest),
    Field = lgra_5_7_1_field_decl(Name, Type, Null, Cap, Markers, Tol, Doc,
        Name ^ id_pos).

    % Any type is admitted here: `DS_VALIDATE_CAPACITY_BAD_TYPE` is the validator's.
    %
    %@spec [LSTR.11.1]
:- pred lstr_11_1_take_capacity(list(positioned)::in, maybe(positioned)::out,
                       list(positioned)::out) is det.

lstr_11_1_take_capacity(Toks, Result, Rest) :-
    ( if
        take_kw("capacity", Toks, T1),
        T1 = [P | T2],
        P ^ tk_tok = int_lit(_)
    then
        Result = yes(P),
        Rest = T2
    else
        Result = no,
        Rest = Toks
    ).

    % The one production that accepts a `type_sym`, which is what restricts the
    % non-`XID` glyphs to type positions with a context-free lexer: keep it the
    % only one.
    %
    %@spec [LLEX.10.8.3]
    %@spec [LCST.4.1.2]
:- pred llex_10_8_3_take_type(list(positioned)::in, ident::out, list(positioned)::out)
    is semidet.

llex_10_8_3_take_type([P | Ps], ident(N, P ^ tk_pos), Ps) :-
    ( P ^ tk_tok = name(N)
    ; P ^ tk_tok = type_sym(N)
    ).

    %@helper
:- pred take_markers(list(positioned)::in, list(slot_marker)::in,
                     list(slot_marker)::out, list(positioned)::out) is det.

take_markers(Toks, Acc, Markers, Rest) :-
    ( if
        take_name(Toks, Id, T1),
        slot_marker_of(Id, M)
    then
        take_markers(T1, [M | Acc], Markers, Rest)
    else
        Markers = reverse(Acc),
        Rest = Toks
    ).

    %@helper
:- pred slot_marker_of(ident::in, slot_marker::out) is semidet.

slot_marker_of(ident(Name, Pos), Marker) :-
    ( Name = "retained", Marker = sm_retained(Pos)
    ; Name = "key", Marker = sm_key(Pos)
    ; Name = "mutable", Marker = sm_mutable(Pos)
    ).

    %@spec [LGRA.5.1]
:- pred lgra_5_1_take_tolerance(list(positioned)::in, maybe(positioned)::out,
                       list(positioned)::out) is det.

lgra_5_1_take_tolerance(Toks, Result, Rest) :-
    ( if
        take_kw("tolerance", Toks, T1),
        T1 = [P | T2],
        ( P ^ tk_tok = int_lit(_) ; P ^ tk_tok = float_lit(_) )
    then
        Result = yes(P),
        Rest = T2
    else
        Result = no,
        Rest = Toks
    ).

    %@helper
:- pred take_field_doc(list(positioned)::in, maybe(string)::out,
                       list(positioned)::out) is det.

take_field_doc(Toks, Result, Rest) :-
    ( if
        Toks = [P | T1],
        ( P ^ tk_tok = single_str(S) ; P ^ tk_tok = triple_str(S) )
    then
        Result = yes(S),
        Rest = T1
    else
        Result = no,
        Rest = Toks
    ).

%-----------------------------------------------------------------------------%

describe_parse_error(pe_expected(What, Found)) =
    "expected " ++ What ++ ", found " ++ describe(Found).
describe_parse_error(pe_expected_eof(Found)) =
    "expected end of file, found " ++ describe(Found).
describe_parse_error(pe_unknown_decl(Kw)) =
    "`" ++ Kw ++ "` does not begin a declaration".
describe_parse_error(pe_empty_schema(Name)) =
    "schema `" ++ Name ++ "` declares no fields".
describe_parse_error(pe_empty_lhs(Name)) =
    "rule `" ++ Name ++ "` matches no patterns".
describe_parse_error(pe_empty_rhs(Name)) =
    "rule `" ++ Name ++ "` has an empty body".
describe_parse_error(pe_empty_series) =
    "a `series` block declares no observation lines".
describe_parse_error(pe_complex_unit(Unit)) =
    "`complex " ++ Unit ++ "`: complex numbers are not in this edition of DS "
        ++ "([LUNI.14.9])".
describe_parse_error(pe_use_plus_chain) =
    "the `+` capability chain is not DS syntax ([LGRA.3.1]): write `use "
        ++ "NAME:` and set each capability on its own indented line, "
        ++ "`realtime: true`".
describe_parse_error(pe_use_paren_group) =
    "a parenthesised capability list is not DS syntax ([LGRA.3.1]): write "
        ++ "`use NAME:` and set each capability on its own indented line, "
        ++ "`realtime: true`".
describe_parse_error(pe_use_empty_block) =
    "`use NAME:` with no settings under it ([LGRA.3.1]): write `use NAME` "
        ++ "when nothing is overridden".
describe_parse_error(pe_duplicate_use(Pos)) =
    "a second `use` directive; the first is at line "
        ++ string.from_int(Pos ^ p_line).
describe_parse_error(pe_empty_import_list) =
    "`from ... import` names nothing to import".
describe_parse_error(pe_import_wildcard) =
    "`from ... import *` is not a DS form ([LIMP.2.4.2]): the selective "
        ++ "import list must enumerate each imported name".
describe_parse_error(pe_empty_formula) =
    "a `unit formula` block declares no formulas; it declares two, one in "
        ++ "each direction ([LUNI.4.5])".
describe_parse_error(pe_formula_not_pair) =
    "a `unit formula` is a pair ([LUNI.4.5]): write `unit formula <name>:` "
        ++ "and, indented beneath it, one formula line in each direction".
describe_parse_error(pe_formula_pair_keyword) =
    "`unit formula pair` is not DS syntax any more ([LUNI.4.5]): every "
        ++ "formula is a pair, so write `unit formula <name>`".
describe_parse_error(pe_formula_modifier_repeated(Word)) =
    "`" ++ Word ++ "` is written twice; each `unit formula` modifier appears "
        ++ "at most once ([LUNI.4.5])".
describe_parse_error(pe_action_block(Head)) =
    "`" ++ Head ++ "` takes no indented block: only `emit`, `publish` and "
        ++ "`call` do ([LGRA.10.8])".
describe_parse_error(pe_test_match_both(Head)) =
    "`" ++ Head ++ "` matches by slot arguments or by `<binding> where "
        ++ "<predicate>`, never both ([LTSL.8.4]): state the slot condition "
        ++ "inside the predicate".

    %@helper
:- func describe_head(lgra_10_1_action_head) = string.

describe_head(ah_log(_, _)) = "log".
describe_head(ah_call(_)) = "call".
describe_head(ah_emit(_)) = "emit".
describe_head(ah_publish(_)) = "publish".
describe_head(ah_cache) = "cache".
describe_head(ah_cache_delete) = "cache_delete".
describe_head(ah_record_event(_)) = "record_event".
describe_head(ah_withdraw(_)) = "withdraw".

%-----------------------------------------------------------------------------%
:- end_module dsc.parse.
%-----------------------------------------------------------------------------%

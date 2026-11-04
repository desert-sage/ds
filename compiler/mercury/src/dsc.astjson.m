% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.astjson -- the syntax tree as `ds_ast` reads it: JSON, one object per
% node of tools/ds_ast/ds.asdl.
%
% The input is the CST, not the AST: `ds_ast.unparse` writes back what the
% author wrote, not `build`'s defaults.
%
% `"_type"` names the ds.asdl constructor, then come its fields, then its
% attributes. `ds_ast`'s reader refuses a name ds.asdl lacks.
%
% Trivia is attached in one pass, in source order. Every statement-like node
% (the ones ds.asdl gives `comments_before`) takes, as it is written:
%   * every comment not yet taken that sits on an EARLIER line, as
%     `comments_before` -- so a comment no node claims still lands before the
%     next one, in order, rather than being lost;
%   * a trailing comment on ITS OWN first line, as `comment_after` -- taken by
%     the outermost node starting on that line, because the walk is pre-order;
%   * the blank run ending on its first line, as `blank_lines_before`.
% What is left at the end is `Module.comments_end`.
%
% `scope ttl`, `cooldown`, `within`, a tolerance and a capacity are token spans
% in the CST, parsed here by `span_json`. A span that does not parse refuses the
% dump, naming where.
%
% A literal's `raw` is its token's source text. A string's value is decoded by
% `dsc.strlit`; docstrings and unit labels are their raw content.
%-----------------------------------------------------------------------------%

:- module dsc.astjson.
:- interface.

:- import_module dsc.cst.
:- import_module dsc.lex.
:- import_module dsc.token.

:- import_module list.

%-----------------------------------------------------------------------------%

    %@helper
:- type astjson_result
    --->    astjson_ok(string)
    ;       astjson_refused(pos, string)
            % A token span the expression reader cannot parse.
    ;       astjson_stopped(pos, string).
            % A bad escape, met only inside a literal.

    %@helper
:- pred astjson_file(string::in, dsc.cst.file::in, list(positioned)::in,
                     trivia::in, astjson_result::out) is det.

    % A string as a JSON string, quotes included: RFC 8259's escapes, and UTF-8
    % otherwise.
    %
    %@helper
:- func json_quote(string) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.expr.
:- import_module dsc.parse.
:- import_module dsc.strlit.

:- import_module bool.
:- import_module char.
:- import_module float.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%
% JSON
%-----------------------------------------------------------------------------%

    % Object members keep the order written, so every node reads `_type`
    % first. `jbad` is a refusal carried in the tree: the walk stays `det`, and
    % `first_bad` finds the first one before anything is rendered.
    %
    %@helper
:- type jv
    --->    jnull
    ;       jbool(bool)
    ;       jint(int)               % a position or a count
    ;       jint64(int64)           % a DS `Int` literal's value
    ;       jfloat(float)
    ;       jstr(string)
    ;       jlist(list(jv))
    ;       jobj(list(pair(string, jv)))
    ;       jbad(pos, string)
    ;       jstop(pos, string).

    %@helper
:- func render(jv) = string.

render(jnull) = "null".
render(jbool(yes)) = "true".
render(jbool(no)) = "false".
render(jint(I)) = string.from_int(I).
render(jint64(I)) = string.int64_to_string(I).
render(jfloat(F)) = string.float_to_string(F).
render(jstr(S)) = quote(S).
render(jlist(Vs)) = "[" ++ string.join_list(",", list.map(render, Vs)) ++ "]".
render(jobj(Ms)) = "{" ++ string.join_list(",", list.map(render_member, Ms))
    ++ "}".
render(jbad(_, _)) = "null".
render(jstop(_, _)) = "null".

    %@helper
:- func render_member(pair(string, jv)) = string.

render_member(K - V) = quote(K) ++ ":" ++ render(V).

    %@helper
:- func quote(string) = string.

quote(S) = "\"" ++ string.append_list(list.map(escape_char,
    string.to_char_list(S))) ++ "\"".

json_quote(S) = quote(S).

    %@helper
:- func escape_char(char) = string.

escape_char(C) = Out :-
    ( if C = '"' then
        Out = "\\\""
    else if C = ('\\') then
        Out = "\\\\"
    else if C = '\n' then
        Out = "\\n"
    else if C = '\r' then
        Out = "\\r"
    else if C = '\t' then
        Out = "\\t"
    else if char.to_int(C) < 0x20 then
        Out = string.format("\\u%04x", [i(char.to_int(C))])
    else
        Out = string.char_to_string(C)
    ).

    % The first refusal in document order, and whether it is a `jstop` (`yes`).
    %
    %@helper
:- pred first_bad(jv::in, bool::out, pos::out, string::out) is semidet.

first_bad(jbad(P, M), no, P, M).
first_bad(jstop(P, M), yes, P, M).
first_bad(jlist(Vs), S, P, M) :-
    list.find_first_map(
        ( pred(V::in, {S1, P1, M1}::out) is semidet :-
            first_bad(V, S1, P1, M1)
        ), Vs, {S, P, M}).
first_bad(jobj(Ms), S, P, M) :-
    list.find_first_map(
        ( pred(Member::in, {S1, P1, M1}::out) is semidet :-
            Member = _ - V,
            first_bad(V, S1, P1, M1)
        ), Ms, {S, P, M}).

%-----------------------------------------------------------------------------%
% Context and trivia
%-----------------------------------------------------------------------------%

    %@helper
:- type cx
    --->    cx(
                cx_lines  :: map(int, list(char)),
                cx_tokens :: map(pos, positioned),
                cx_all    :: list(positioned)
            ).

    % The trivia not yet attached: comments in source order, and the blank
    % run ending before each line.
    %
    %@helper
:- type tv
    --->    tv(
                tv_comments :: list(comment),
                tv_blanks   :: map(int, int)
            ).

astjson_file(Source, File, Tokens, Trivia, Result) :-
    Lines = source_lines(Source),
    % Only tokens with width: layout's synthetic tokens sit on a real token's
    % position at zero width, and would take its slot in the map.
    TokenMap = list.foldl(
        ( func(T, M0) =
            ( if T ^ tk_end = T ^ tk_pos then M0
            else map.set(M0, T ^ tk_pos, T) )
        ), Tokens, map.init),
    Cx = cx(Lines, TokenMap, Tokens),
    Blanks = list.foldl(
        ( func(Run, M0) = map.set(M0, Run ^ br_line, Run ^ br_count) ),
        Trivia ^ tv_blank_runs, map.init),
    Tv0 = tv(Trivia ^ tv_comments, Blanks),
    module_json(Cx, File, Json, Tv0, _),
    ( if first_bad(Json, Stop, P, M) then
        (
            Stop = yes,
            Result = astjson_stopped(P, M)
        ;
            Stop = no,
            Result = astjson_refused(P, M)
        )
    else
        Result = astjson_ok(render(Json))
    ).

    %@helper
:- func source_lines(string) = map(int, list(char)).

source_lines(Source) = Map :-
    Split = string.split_at_char('\n', Source),
    list.foldl2(
        ( pred(L::in, N0::in, N::out, M0::in, M::out) is det :-
            N = N0 + 1,
            Chars0 = string.to_char_list(L),
            ( if list.split_last(Chars0, Init, '\r') then
                Chars = Init
            else
                Chars = Chars0
            ),
            map.set(N0, Chars, M0, M)
        ), Split, 1, _, map.init, Map).

    % A token's source text, from its start to its (exclusive) end, across
    % lines when it spans them -- a `"""` string does.
    %
    %@helper
:- func token_text(cx, positioned) = string.

token_text(Cx, T) = Text :-
    pos(L1, C1) = T ^ tk_pos,
    pos(L2, C2) = T ^ tk_end,
    ( if L1 = L2 then
        Text = string.from_char_list(slice(line_chars(Cx, L1), C1, C2))
    else
        First = drop_n(C1, line_chars(Cx, L1)),
        Middle = list.map(line_chars(Cx), range_list(L1 + 1, L2 - 1)),
        Last = list.take_upto(C2, line_chars(Cx, L2)),
        Text = string.join_list("\n",
            list.map(string.from_char_list, [First] ++ Middle ++ [Last]))
    ).

    %@helper
:- func line_chars(cx, int) = list(char).

line_chars(Cx, L) =
    ( if map.search(Cx ^ cx_lines, L, Cs) then Cs else [] ).

    %@helper
:- func slice(list(char), int, int) = list(char).

slice(Cs, From, To) = list.take_upto(To - From, drop_n(From, Cs)).

    %@helper
:- func drop_n(int, list(T)) = list(T).

drop_n(N, Xs) =
    ( if N =< 0 then Xs
    else if Xs = [_ | Rest] then drop_n(N - 1, Rest)
    else [] ).

    %@helper
:- func range_list(int, int) = list(int).

range_list(Lo, Hi) = ( if Lo > Hi then [] else [Lo | range_list(Lo + 1, Hi)] ).

    %@helper
:- func raw_at(cx, pos) = jv.

raw_at(Cx, P) =
    ( if map.search(Cx ^ cx_tokens, P, T) then jstr(token_text(Cx, T))
    else jnull ).

    % INT64_MIN is two tokens and one literal, an `ex_int` positioned at the minus.
    %
    %@helper
:- func int_raw_at(cx, pos) = jv.

int_raw_at(Cx, P) = Raw :-
    ( if
        map.search(Cx ^ cx_tokens, P, T),
        T ^ tk_tok = minus,
        list.find_first_match(
            ( pred(Tok::in) is semidet :- pos_after(Tok ^ tk_pos, P) ),
            Cx ^ cx_all, Magnitude)
    then
        Raw = jstr("-" ++ token_text(Cx, Magnitude))
    else
        Raw = raw_at(Cx, P)
    ).

    % A log message is a string with no position of its own in the CST: it is
    % the first string token after the action's head.
    %
    %@helper
:- func string_after(cx, pos) = jv.

string_after(Cx, P) =
    ( if
        list.find_first_match(
            ( pred(Tok::in) is semidet :-
                pos_after(Tok ^ tk_pos, P),
                ( Tok ^ tk_tok = single_str(_) ; Tok ^ tk_tok = triple_str(_) )
            ), Cx ^ cx_all, T)
    then jstr(token_text(Cx, T))
    else jnull ).

    %@helper
:- pred pos_after(pos::in, pos::in) is semidet.

pos_after(pos(L1, C1), pos(L2, C2)) :-
    ( L1 > L2 ; L1 = L2, C1 > C2 ).

    % The location attributes every positioned node carries. The end is not
    % known for most CST nodes, so it is written null and `ds_ast` leaves it
    % unset, as Python leaves it when a node was built by hand.
    %
    %@helper
:- func loc(pos) = list(pair(string, jv)).

loc(pos(L, C)) = ["lineno" - jint(L), "col_offset" - jint(C),
    "end_lineno" - jnull, "end_col_offset" - jnull].

    % The location of a node whose end is known: `End` is exclusive, the
    % code-point column just past its last character, as Python's is.
    %
    %@helper
:- func span_loc(pos, pos) = list(pair(string, jv)).

span_loc(pos(L, C), pos(EL, EC)) = ["lineno" - jint(L), "col_offset" - jint(C),
    "end_lineno" - jint(EL), "end_col_offset" - jint(EC)].

    %@helper
:- func short_loc(pos) = list(pair(string, jv)).

short_loc(pos(L, C)) = ["lineno" - jint(L), "col_offset" - jint(C)].

    % A statement-like node's attributes: its location and its trivia. See
    % the header for the three rules.
    %
    %@helper
:- pred stmt(pos::in, list(pair(string, jv))::out, tv::in, tv::out) is det.

stmt(P, Attrs, !Tv) :-
    L = P ^ p_line,
    take_before(L, Before, !Tv),
    ( if
        !.Tv ^ tv_comments = [C | Cs],
        C ^ cm_pos ^ p_line = L,
        C ^ cm_placement = cp_trailing
    then
        After = comment_json(!.Tv, C),
        !Tv ^ tv_comments := Cs
    else
        After = jnull
    ),
    Blank = blank_before(!.Tv, L),
    Attrs = loc(P) ++ ["comments_before" - jlist(Before),
        "comment_after" - After, "blank_lines_before" - jint(Blank)].

    %@helper
:- pred take_before(int::in, list(jv)::out, tv::in, tv::out) is det.

take_before(L, Before, !Tv) :-
    list.take_while(
        ( pred(C::in) is semidet :- C ^ cm_pos ^ p_line < L ),
        !.Tv ^ tv_comments, Taken, Rest),
    Before = list.map(comment_json(!.Tv), Taken),
    !Tv ^ tv_comments := Rest.

    %@helper
:- func blank_before(tv, int) = int.

blank_before(Tv, L) = ( if map.search(Tv ^ tv_blanks, L, N) then N else 0 ).

    %@helper
:- func comment_json(tv, comment) = jv.

comment_json(Tv, comment(Text, P, _)) =
    jobj(["_type" - jstr("comment"), "text" - jstr(Text)]
        ++ short_loc(P)
        ++ ["blank_lines_before" - jint(blank_before(Tv, P ^ p_line))]).

    %@helper
:- func node(string, list(pair(string, jv)), list(pair(string, jv))) = jv.

node(Type, Fields, Attrs) = jobj(["_type" - jstr(Type)] ++ Fields ++ Attrs).

    %@helper
:- func leaf(string) = jv.

leaf(Type) = jobj(["_type" - jstr(Type)]).

    %@helper
:- func opt(maybe(T), func(T) = jv) = jv.

opt(no, _) = jnull.
opt(yes(X), F) = F(X).

    %@helper
:- func name_of(ident) = jv.

name_of(Id) = jstr(Id ^ id_name).

    % Not `NoResponse`: that is a `.dstest` stub's reply, and carries a position.
    %
    %@helper
:- func response_json(response_decl) = jv.

response_json(rd_schema(Id)) = node("ResponseSchema", ["name" - name_of(Id)],
    []).
response_json(rd_none(_)) = leaf("NoServiceResponse").
response_json(rd_absent) = jnull.

    %@helper
:- func names(list(ident)) = jv.

names(Ids) = jlist(list.map(name_of, Ids)).

    %@helper
:- func opt_str(maybe(string)) = jv.

opt_str(no) = jnull.
opt_str(yes(S)) = jstr(S).

    %@helper
:- func nullable_json(nullability) = jv.

nullable_json(nullable) = jbool(yes).
nullable_json(non_null) = jbool(no).

    %@helper
:- pred stmts(pred(T, jv, tv, tv), list(T), jv, tv, tv).
    %@helper
:- mode stmts(pred(in, out, in, out) is det, in, out, in, out) is det.

stmts(P, Xs, jlist(Js), !Tv) :-
    list.map_foldl(P, Xs, Js, !Tv).

%-----------------------------------------------------------------------------%
% The module and its declarations
%-----------------------------------------------------------------------------%

    %@helper
:- func setting_json(setting_line) = jv.

setting_json(setting_line(Cap, Value)) =
    node("Setting", ["capability" - name_of(Cap), "value" - jbool(Value)],
        []).

    %@helper
:- pred module_json(cx::in, dsc.cst.file::in, jv::out, tv::in, tv::out)
    is det.

module_json(Cx, file(MaybeUse, Decls), Json, !Tv) :-
    (
        MaybeUse = no,
        UseJ = jnull
    ;
        MaybeUse = yes(use_decl(Base, Lines, P)),
        stmt(P, A, !Tv),
        UseJ = node("Use", ["dialect" - name_of(Base),
            "settings" - jlist(list.map(setting_json, Lines))], A)
    ),
    stmts(decl_json(Cx), Decls, Body, !Tv),
    End = list.map(comment_json(!.Tv), !.Tv ^ tv_comments),
    !Tv ^ tv_comments := [],
    Json = node("Module", ["use" - UseJ, "body" - Body,
        "comments_end" - jlist(End)], []).

    %@helper
:- pred decl_json(cx::in, top_decl::in, jv::out, tv::in, tv::out) is det.

decl_json(Cx, td_schema(S), J, !Tv) :-
    S = lgra_5_1_schema_decl(Name, Life, Doc, Fields, P),
    stmt(P, A, !Tv),
    stmts(slot_json(Cx), Fields, Slots, !Tv),
    J = node("Schema", ["name" - name_of(Name),
        "scope" - opt(Life, scope_json(Cx)), "docstring" - opt_str(Doc),
        "slots" - Slots], A).
decl_json(Cx, td_rule(R), J, !Tv) :-
    R = lgra_6_1_rule_decl(Name, Mods, Doc, Lhs, Rhs, P),
    stmt(P, A, !Tv),
    Rhs = lgra_6_1_rule_rhs(Lets, Actions, Afters),
    stmts(lhs_json(Cx), Lhs, LhsJ, !Tv),
    stmts(let_json(Cx), Lets, LetsJ, !Tv),
    stmts(action_json(Cx), Actions, ActionsJ, !Tv),
    stmts(after_json(Cx), Afters, AftersJ, !Tv),
    J = node("Rule", ["name" - name_of(Name),
        "rate" - jlist(list.map(rate_json(Cx), Mods)),
        "docstring" - opt_str(Doc), "lhs" - LhsJ, "lets" - LetsJ,
        "actions" - ActionsJ, "afters" - AftersJ], A).
decl_json(Cx, td_const(lgra_4_1_const_decl(Name, Form, P)), J, !Tv) :-
    stmt(P, A, !Tv),
    (
        Form = cf_value(Ann, E),
        J = node("Const", ["name" - name_of(Name),
            "annotation" - opt(Ann, annotation_json),
            "value" - expr_json(Cx, E), "colon_form" - jbool(no)], A)
    ;
        Form = cf_colon_literal(E),
        J = node("Const", ["name" - name_of(Name), "annotation" - jnull,
            "value" - expr_json(Cx, E), "colon_form" - jbool(yes)], A)
    ).
decl_json(Cx, td_series(S), J, !Tv) :-
    S = lgra_7_1_series_decl(lgra_7_3_slot_ref(Schema, Slot), Opts, Doc,
        Lines, P),
    stmt(P, A, !Tv),
    stmts(series_line_json(Cx), Lines, LinesJ, !Tv),
    J = node("Series", ["schema" - opt(Schema, name_of),
        "slot" - name_of(Slot),
        "options" - jlist(list.map(series_option_json(Cx), Opts)),
        "docstring" - opt_str(Doc), "lines" - LinesJ], A).
decl_json(Cx, td_service(S), J, !Tv) :-
    S = service_decl(Name, Doc, Kwargs, Response, Hydration, P),
    stmt(P, A, !Tv),
    stmts(service_kwarg_json(Cx), Kwargs, KwargsJ, !Tv),
    stmts(hydration_json(Cx), Hydration, HydJ, !Tv),
    J = node("Service", ["name" - names(Name), "docstring" - opt_str(Doc),
        "kwargs" - KwargsJ, "response" - response_json(Response),
        "hydration" - HydJ], A).
decl_json(Cx, td_unit(U), J, !Tv) :-
    unit_json(Cx, U, J, !Tv).
decl_json(_, td_opaque(lopq_2_1_opaque_decl(Name, Repr, P)), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("Opaque", ["name" - name_of(Name),
        "representation" - name_of(Repr)], A).
decl_json(Cx, td_test(ltsl_2_1_test_decl(Name, Sections, P)), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(section_json(Cx), Sections, SectionsJ, !Tv),
    J = node("Test", ["name" - expr_json(Cx, Name), "sections" - SectionsJ],
        A).
decl_json(Cx, td_initial(lgra_24_1_initial_block(Items, P)), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(initial_json(Cx), Items, ItemsJ, !Tv),
    J = node("InitialBlock", ["items" - ItemsJ], A).
decl_json(_, td_import(I), J, !Tv) :-
    (
        I = limp_2_1_1_qualified(Path, Alias, P),
        stmt(P, A, !Tv),
        J = node("Import", ["path" - names(Path),
            "asname" - opt(Alias, name_of)], A)
    ;
        I = limp_2_1_1_selective(Path, Items, P),
        stmt(P, A, !Tv),
        J = node("ImportFrom", ["path" - names(Path),
            "names" - jlist(list.map(alias_json, Items))], A)
    ).

%-----------------------------------------------------------------------------%
% Tests -- [LTSL]
%-----------------------------------------------------------------------------%

    %@helper
:- pred section_json(cx::in, ltsl_2_3_section::in, jv::out, tv::in, tv::out)
    is det.

section_json(Cx, Section, J, !Tv) :-
    (
        Section = ts_initial(Items, P),
        stmt(P, A, !Tv),
        stmts(initial_json(Cx), Items, ItemsJ, !Tv),
        J = node("Initial", ["items" - ItemsJ], A)
    ;
        Section = ts_inputs(Blocks, P),
        stmt(P, A, !Tv),
        stmts(at_json(Cx), Blocks, BlocksJ, !Tv),
        J = node("Inputs", ["blocks" - BlocksJ], A)
    ;
        Section = ts_responses(Stubs, P),
        stmt(P, A, !Tv),
        stmts(stub_json(Cx), Stubs, StubsJ, !Tv),
        J = node("Responses", ["stubs" - StubsJ], A)
    ;
        Section = ts_produces(Assertions, P),
        stmt(P, A, !Tv),
        stmts(assertion_json(Cx), Assertions, AssertionsJ, !Tv),
        J = node("Produces", ["assertions" - AssertionsJ], A)
    ;
        Section = ts_until(When, P),
        stmt(P, A, !Tv),
        J = node("Until", ["when" - expr_json(Cx, When)], A)
    ).

    %@helper
:- pred initial_json(cx::in, ltsl_5_2_initial_item::in, jv::out,
                     tv::in, tv::out) is det.

initial_json(Cx, Item, J, !Tv) :-
    (
        Item = ti_fact(Fact),
        stmt(Fact ^ tf_pos, A, !Tv),
        fact_json(Cx, Fact, FactJ, !Tv),
        J = node("InitialFact", ["fact" - FactJ], A)
    ;
        Item = ti_cache(Key, Value, P),
        stmt(P, A, !Tv),
        J = node("CacheSeed", ["key" - expr_json(Cx, Key),
            "value" - expr_json(Cx, Value)], A)
    ;
        Item = ti_cache_block(Seeds, P),
        stmt(P, A, !Tv),
        stmts(seed_json(Cx), Seeds, SeedsJ, !Tv),
        J = node("CacheBlock", ["seeds" - SeedsJ], A)
    ).

    %@helper
:- pred seed_json(cx::in, ltsl_5_2_seed::in, jv::out, tv::in, tv::out)
    is det.

seed_json(Cx, ltsl_5_2_seed(Key, Value, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("Seed", ["key" - expr_json(Cx, Key),
        "value" - expr_json(Cx, Value)], A).

    % A constructed fact. Its line's trivia goes to whatever wraps it when
    % something does (`InitialFact`, `Reply`), because that node starts on
    % the same line and is written first.
    %
    %@helper
:- pred fact_json(cx::in, ltsl_4_1_fact::in, jv::out, tv::in, tv::out)
    is det.

fact_json(Cx, ltsl_4_1_fact(Schema, Args, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(arg_json(Cx), Args, ArgsJ, !Tv),
    J = node("Fact", ["schema" - type_ref_json(Schema), "args" - ArgsJ], A).

    %@helper
:- pred at_json(cx::in, ltsl_3_3_at_block::in, jv::out, tv::in, tv::out)
    is det.

at_json(Cx, ltsl_3_3_at_block(When, Facts, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(fact_json(Cx), Facts, FactsJ, !Tv),
    J = node("At", ["when" - expr_json(Cx, When), "facts" - FactsJ], A).

    %@helper
:- pred stub_json(cx::in, ltsl_7_2_stub::in, jv::out, tv::in, tv::out)
    is det.

stub_json(Cx, ltsl_7_2_stub(Ref, Args, Corr, After, Replies, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(arg_json(Cx), Args, ArgsJ, !Tv),
    stmts(reply_json(Cx), Replies, RepliesJ, !Tv),
    service_ref_parts(Ref, Lib, Service),
    J = node("ForCall", ["library" - names(Lib), "service" - names(Service),
        "args" - ArgsJ, "correlation" - opt(Corr, expr_json(Cx)),
        "after" - opt(After, expr_json(Cx)), "replies" - RepliesJ], A).

    %@helper
:- pred reply_json(cx::in, ltsl_7_3_reply::in, jv::out, tv::in, tv::out)
    is det.

reply_json(Cx, Reply, J, !Tv) :-
    (
        Reply = tr_fact(Fact),
        stmt(Fact ^ tf_pos, A, !Tv),
        fact_json(Cx, Fact, FactJ, !Tv),
        J = node("Reply", ["fact" - FactJ], A)
    ;
        Reply = tr_no_response(P),
        stmt(P, A, !Tv),
        J = node("NoResponse", [], A)
    ).

    %@helper
:- pred assertion_json(cx::in, ltsl_8_2_assertion::in, jv::out,
                       tv::in, tv::out) is det.

assertion_json(Cx, ltsl_8_2_assertion(Never, Head, P), J, !Tv) :-
    stmt(P, A, !Tv),
    head_json(Cx, Head, HeadJ, !Tv),
    J = node("Assertion", ["never" - jbool(Never), "head" - HeadJ], A).

    %@helper
:- pred head_json(cx::in, ltsl_8_2_head::in, jv::out, tv::in, tv::out)
    is det.

head_json(Cx, Head, J, !Tv) :-
    (
        Head = th_activated(Rule),
        J = node("Activated", ["rule" - name_of(Rule)], [])
    ;
        Head = th_emitted(Schema, Args, Where),
        matched_json(Cx, "Emitted", Schema, Args, Where, J, !Tv)
    ;
        Head = th_published(Schema, Args, Where),
        matched_json(Cx, "Published", Schema, Args, Where, J, !Tv)
    ;
        Head = th_retracted(Schema, Args),
        stmts(arg_json(Cx), Args, ArgsJ, !Tv),
        J = node("Retracted", ["schema" - type_ref_json(Schema),
            "args" - ArgsJ], [])
    ;
        Head = th_recorded(Kind),
        J = node("Recorded", ["kind" - name_of(Kind)], [])
    ;
        Head = th_called(Ref, Corr),
        service_ref_parts(Ref, Lib, Service),
        J = node("Called", ["library" - names(Lib),
            "service" - names(Service),
            "correlation" - opt(Corr, expr_json(Cx))], [])
    ;
        Head = th_cached(Key, Value),
        J = node("Cached", ["key" - expr_json(Cx, Key),
            "value" - opt(Value, expr_json(Cx))], [])
    ;
        Head = th_cache_deleted(Key),
        J = node("CacheDeleted", ["key" - expr_json(Cx, Key)], [])
    ;
        Head = th_logged(Level, Sub),
        J = node("Logged", ["level" - log_level_json(Level),
            "substring" - opt(Sub, expr_json(Cx))], [])
    ;
        Head = th_wm_has(Schema, Args),
        stmts(arg_json(Cx), Args, ArgsJ, !Tv),
        J = node("WmHas", ["schema" - type_ref_json(Schema), "args" - ArgsJ],
            [])
    ;
        Head = th_wm_count(Schema, Count),
        J = node("WmCount", ["schema" - type_ref_json(Schema),
            "count" - expr_json(Cx, Count)], [])
    ;
        Head = th_wm_empty,
        J = leaf("WmEmpty")
    ).

    %@helper
:- pred matched_json(cx::in, string::in, lgra_8_1_type_ref::in,
                     list(lgra_10_3_1_action_arg)::in,
                     maybe(ltsl_8_4_where)::in, jv::out,
                     tv::in, tv::out) is det.

matched_json(Cx, Type, Schema, Args, Where, J, !Tv) :-
    stmts(arg_json(Cx), Args, ArgsJ, !Tv),
    (
        Where = yes(ltsl_8_4_where(Binding, Pred)),
        BindingJ = name_of(Binding),
        PredJ = expr_json(Cx, Pred)
    ;
        Where = no,
        BindingJ = jnull,
        PredJ = jnull
    ),
    J = node(Type, ["schema" - type_ref_json(Schema), "args" - ArgsJ,
        "binding" - BindingJ, "where" - PredJ], []).

    %@helper
:- pred service_ref_parts(lgra_10_1_service_ref::in, list(ident)::out,
                          list(ident)::out) is det.

service_ref_parts(sr_bare(Service), [], Service).

    %@helper
:- func alias_json(limp_2_1_1_import_item) = jv.

alias_json(limp_2_1_1_import_item(Name, Alias, P)) =
    node("alias", ["name" - name_of(Name), "asname" - opt(Alias, name_of)],
        loc(P)).

%-----------------------------------------------------------------------------%
% Schemas
%-----------------------------------------------------------------------------%

    %@helper
:- func scope_json(cx, lgra_5_2_lifecycle) = jv.

scope_json(_, lc_explicit) = leaf("Explicit").
scope_json(_, lc_activation) = leaf("Activation").
scope_json(_, lc_logical(Amb)) =
    node("Logical", ["ambient" - ambient_json(Amb)], []).
scope_json(Cx, lc_ttl(Span, Amb)) =
    node("Ttl", ["duration" - span_json(Cx, "`scope ttl` duration", Span),
        "ambient" - ambient_json(Amb)], []).
scope_json(Cx, lc_unprefixed(L)) =
    node("Unprefixed", ["scope" - scope_json(Cx, L)], []).
scope_json(_, lc_bare_ambient) = leaf("BareAmbient").

    %@helper
:- func ambient_json(ambient) = jv.

ambient_json(ambient) = jbool(yes).
ambient_json(not_ambient) = jbool(no).

    %@helper
:- pred slot_json(cx::in, lgra_5_7_1_field_decl::in, jv::out,
                  tv::in, tv::out) is det.

slot_json(Cx, F, J, !Tv) :-
    F = lgra_5_7_1_field_decl(Name, Type, Null, Cap, Markers, Tol, Doc, P),
    stmt(P, A, !Tv),
    (
        Tol = no,
        TolJ = jnull
    ;
        Tol = yes(T),
        TolJ = span_json(Cx, "tolerance", [T])
    ),
    (
        Cap = no,
        CapJ = jnull
    ;
        Cap = yes(C),
        CapJ = span_json(Cx, "capacity", [C])
    ),
    J = node("Slot", ["name" - name_of(Name), "type" - name_of(Type),
        "nullable" - nullable_json(Null), "capacity" - CapJ,
        "markers" - jlist(list.map(marker_json, Markers)),
        "tolerance" - TolJ, "docstring" - opt_str(Doc)], A).

    %@helper
:- func marker_json(slot_marker) = jv.

marker_json(sm_key(P)) = node("Key", [], short_loc(P)).
marker_json(sm_mutable(P)) = node("Mutable", [], short_loc(P)).
marker_json(sm_sampled(P)) = node("Sampled", [], short_loc(P)).
marker_json(sm_retained(P)) = node("Retained", [], short_loc(P)).

%-----------------------------------------------------------------------------%
% Rules
%-----------------------------------------------------------------------------%

    %@helper
:- func rate_json(cx, lgra_6_1_rule_modifier) = jv.

rate_json(Cx, rm_cooldown(Span, P)) =
    node("Cooldown", ["duration" - span_json(Cx, "`cooldown` duration", Span)],
        short_loc(P)).
    % `by: none` is the empty list: `rate_key` otherwise writes at least one path.
rate_json(_, rm_by(rk_none, P)) =
    node("RateKey", ["paths" - jlist([])], short_loc(P)).
rate_json(Cx, rm_by(rk_paths(Paths), P)) =
    node("RateKey", ["paths" - jlist(list.map(key_path_json(Cx), Paths))],
        short_loc(P)).

    %@helper
:- func key_path_json(cx, lgra_6_1_key_path) = jv.

key_path_json(Cx, key_path(B, S)) =
    expr_json(Cx, ex_slot(ex_name(B), S, B ^ id_pos)).

    %@helper
:- pred lhs_json(cx::in, lgra_8_1_lhs_clause::in, jv::out, tv::in, tv::out)
    is det.

lhs_json(Cx, lc_pattern(Pat), J, !Tv) :-
    stmt(pattern_pos(Pat), A, !Tv),
    J = node("PatternClause", ["pattern" - pattern_json(Cx, Pat)], A).
lhs_json(Cx, lc_then(Step), J, !Tv) :-
    stmt(Step ^ ts_pos, A, !Tv),
    J = node("ThenClause", ["step" - then_json(Cx, Step)], A).

    %@helper
:- func pattern_pos(lgra_8_1_pattern) = pos.

pattern_pos(pat_simple(B)) = B ^ pb_pos.
pattern_pos(pat_negated(_, _, P)) = P.
pattern_pos(pat_sequence(_, _, _, P)) = P.

    %@helper
:- func pattern_json(cx, lgra_8_1_pattern) = jv.

pattern_json(Cx, pat_simple(B)) =
    node("Simple", ["body" - body_json(Cx, B)], []).
pattern_json(Cx, pat_negated(B, Parens, _)) =
    node("Negated", ["body" - body_json(Cx, B),
        "parenthesised" - jbool(( if Parens = np_parenthesised then yes
            else no ))], []).
pattern_json(Cx, pat_sequence(Latest, Head, Steps, _)) =
    node("Sequence", ["latest" - latest_json(Latest),
        "head" - body_json(Cx, Head),
        "steps" - jlist(list.map(then_json(Cx), Steps))], []).

    %@helper
:- func latest_json(sequence_latest) = jv.

latest_json(sl_latest) = jbool(yes).
latest_json(sl_plain) = jbool(no).

    %@helper
:- func body_json(cx, lgra_8_1_pattern_body) = jv.

body_json(Cx, lgra_8_1_pattern_body(Type, Binding, Within, Where, Cap, P)) =
    node("PatternBody", ["type" - type_ref_json(Type),
        "binding" - opt(Binding, name_of),
        "within" - opt(Within, span_json(Cx, "`within` window")),
        "where" - opt(Where, expr_json(Cx)),
        % `where` is the whole condition either way, so `unparse` writes
        % `where (a, b) = <where>` when this is non-empty.
        "captures" - names(( if Cap = yes(C) then C ^ cap_names else [] ))],
        loc(P)).

    %@helper
:- func then_json(cx, lgra_8_5_2_then_step) = jv.

then_json(Cx, lgra_8_5_2_then_step(Latest, Body, Within, P)) =
    node("Then", ["latest" - latest_json(Latest),
        "body" - body_json(Cx, Body),
        "within" - span_json(Cx, "`within` window", Within)], loc(P)).

    %@helper
:- func type_ref_json(lgra_8_1_type_ref) = jv.

type_ref_json(tr_bare(Name)) = node("TypeName", ["name" - name_of(Name)], []).
type_ref_json(tr_qualified(Lib, Name)) =
    node("QualifiedType", ["library" - names(Lib), "name" - name_of(Name)], []).

    %@helper
:- pred let_json(cx::in, lgra_6_1_let_decl::in, jv::out, tv::in, tv::out)
    is det.

let_json(Cx, lgra_6_1_let_decl(Bindings, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(let_binding_json(Cx), Bindings, BJ, !Tv),
    J = node("Let", ["bindings" - BJ], A).

    %@helper
:- pred let_binding_json(cx::in, lgra_6_1_let_binding::in, jv::out,
                         tv::in, tv::out) is det.

let_binding_json(Cx, lb_simple(Name, Ann, E, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("LetName", ["name" - name_of(Name),
        "annotation" - opt(Ann, annotation_json),
        "value" - expr_json(Cx, E)], A).
let_binding_json(Cx, lb_capture(Names, E, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("LetCapture", ["names" - names(Names),
        "value" - expr_json(Cx, E)], A).

    %@helper
:- func annotation_json(lgra_6_7_2_annotation) = jv.

annotation_json(lgra_6_7_2_annotation(Type, Null)) =
    node("Annotation", ["type" - name_of(Type),
        "nullable" - nullable_json(Null)], []).

%-----------------------------------------------------------------------------%
% Actions
%-----------------------------------------------------------------------------%

    %@helper
:- pred action_json(cx::in, lgra_10_1_action::in, jv::out, tv::in, tv::out)
    is det.

action_json(Cx, lgra_10_1_action(Head, Args, Block, As, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(arg_json(Cx), Args, ArgsJ, !Tv),
    (
        Block = ab_none,
        BlockJ = jlist([]),
        ContsJ = jlist([])
    ;
        Block = ab_kwargs(Kws),
        stmts(arg_json(Cx), Kws, BlockJ, !Tv),
        ContsJ = jlist([])
    ;
        Block = ab_call(Kws, Conts),
        stmts(arg_json(Cx), Kws, BlockJ, !Tv),
        stmts(continuation_json(Cx), Conts, ContsJ, !Tv)
    ),
    (
        Head = ah_log(Level, _),
        J = node("Log", ["level" - log_level_json(Level),
            "message" - log_message_json(Cx, Head, P), "args" - ArgsJ], A)
    ;
        Head = ah_call(sr_bare(Service)),
        % `library` is in ds.asdl's `ServiceCall`, and is always empty.
        J = node("ServiceCall", ["library" - names([]),
            "service" - names(Service), "args" - ArgsJ, "block" - BlockJ,
            "continuations" - ContsJ,
            "correlation" - opt(As, expr_json(Cx))], A)
    ;
        Head = ah_emit(Schema),
        J = node("Emit", ["schema" - type_ref_json(Schema), "args" - ArgsJ,
            "block" - BlockJ], A)
    ;
        Head = ah_publish(Schema),
        J = node("Publish", ["schema" - type_ref_json(Schema), "args" - ArgsJ,
            "block" - BlockJ], A)
    ;
        Head = ah_cache,
        J = node("Cache", ["args" - ArgsJ, "block" - BlockJ], A)
    ;
        Head = ah_cache_delete,
        J = node("CacheDelete", ["args" - ArgsJ, "block" - BlockJ], A)
    ;
        Head = ah_record_event(Schema),
        J = node("RecordEvent", ["schema" - type_ref_json(Schema),
            "args" - ArgsJ, "block" - BlockJ], A)
    ;
        Head = ah_withdraw(Binding),
        J = node("Withdraw", ["binding" - name_of(Binding), "args" - ArgsJ],
            A)
    ).

    %@helper
:- func log_message_json(cx, lgra_10_1_action_head, pos) = jv.

log_message_json(Cx, Head, P) = J :-
    ( if Head = ah_log(_, Msg) then
        string_fields(Cx, Msg, P, string_after(Cx, P), Type, Fields),
        J = node(Type, Fields, loc(P))
    else
        J = jnull
    ).

    % A `Constant` of decoded text, or with an interpolation site a `JoinedStr`.
    %
    % A site's expression is placed on the literal and its literals carry no
    % `raw`: its own positions are offsets into the body, lexed on its own.
    %
    %@helper
:- pred string_fields(cx::in, string::in, pos::in, jv::in, string::out,
                      list(pair(string, jv))::out) is det.

string_fields(Cx, Text, P, Raw, Type, Fields) :-
    Parts = merge_text(list.map(part, lgra_2_9_6_7_pieces(
        string.to_char_list(Text)))),
    ( if list.find_first_match(is_site_part, Parts, _) then
        SiteCx = Cx ^ cx_tokens := map.init,
        Type = "JoinedStr",
        Fields = ["values" - jlist(list.map(part_json(SiteCx, P), Parts)),
            "raw" - Raw]
    else
        Type = "Constant",
        Fields = ["value" - decoded_text(P,
                list.condense(list.map(part_chars, Parts))),
            "raw" - Raw]
    ).

    % A site whose body is not an expression is text here, braces and all: whether
    % interpolation is eligible at this position is `validate`'s.
    %
    %@helper
:- type part
    --->    part_site(list(char), maybe(list(char)), lgra_9_3_1_expr)
    ;       part_text(list(char)).

    %@helper
:- func part(piece) = part.

part(Piece) = Part :-
    ( if
        Piece = p_site(Body),
        site_split(Body, Path, Format),
        site_expr(Path, E)
    then
        Part = part_site(Path, Format, E)
    else
        Part = part_text(piece_text(Piece))
    ).

    % Adjacent text parts joined, so a site that fell back to text does not
    % split the run around it.
    %
    %@helper
:- func merge_text(list(part)) = list(part).

merge_text([]) = [].
merge_text([P | Ps]) = Merged :-
    Rest = merge_text(Ps),
    ( if P = part_text(A), Rest = [part_text(B) | Tail] then
        Merged = [part_text(A ++ B) | Tail]
    else
        Merged = [P | Rest]
    ).

    %@helper
:- pred is_site_part(part::in) is semidet.

is_site_part(part_site(_, _, _)).

    %@helper
:- func part_chars(part) = list(char).

part_chars(part_text(Chars)) = Chars.
part_chars(part_site(Path, Format, _)) = ['{' | Path] ++ Spec ++ ['}'] :-
    ( Format = yes(F), Spec = [':' | F]
    ; Format = no, Spec = []
    ).

    % A piece as literal text. `{}` and an unclosed `{` are text, as the
    % lowering reads them -- `validate` refuses both where interpolation is
    % eligible -- and so is a site that `part` could not read.
    %
    %@helper
:- func piece_text(piece) = list(char).

piece_text(p_text(Chars)) = Chars.
piece_text(p_site(Body)) = ['{' | Body] ++ ['}'].
piece_text(p_empty) = ['{', '}'].
piece_text(p_unclosed(Chars)) = Chars.

    %@helper
:- func part_json(cx, pos, part) = jv.

part_json(Cx, P, part_site(_, Format, E)) =
    node("FormattedValue", ["value" - expr_json(Cx, at_pos(P, E)),
        "format_spec" - opt_chars(Format)], loc(P)).
part_json(_, P, part_text(Chars)) =
    node("Constant", ["value" - decoded_text(P, Chars), "raw" - jnull],
        loc(P)).

    %@helper
:- func opt_chars(maybe(list(char))) = jv.

opt_chars(no) = jnull.
opt_chars(yes(Chars)) = jstr(string.from_char_list(Chars)).

    % A bad escape stops the dump as a syntax error.
    %
    %@helper
:- func decoded_text(pos, list(char)) = jv.

decoded_text(P, Chars) = J :-
    Decoded = lgra_2_9_4_decode(Chars),
    (
        Decoded = decoded(Text),
        J = jstr(string.from_char_list(Text))
    ;
        Decoded = bad_escape(Reason),
        J = jstop(P, "invalid escape sequence: " ++ Reason
            ++ " ([LGRA.2.9.4])")
    ).

    %@helper
:- func log_level_json(lgra_10_1_1_log_level) = jv.

log_level_json(ll_debug) = leaf("LogDebug").
log_level_json(ll_info) = leaf("LogInfo").
log_level_json(ll_warning) = leaf("LogWarning").
log_level_json(ll_error) = leaf("LogError").
log_level_json(ll_critical) = leaf("LogCritical").
log_level_json(ll_unknown(S)) = node("LogUnknown", ["written" - jstr(S)], []).

    %@helper
:- pred arg_json(cx::in, lgra_10_3_1_action_arg::in, jv::out, tv::in, tv::out)
    is det.

arg_json(Cx, aa_kwarg(Name, E, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("keyword", ["arg" - name_of(Name), "value" - expr_json(Cx, E)], A).
arg_json(_, aa_flag(Name), J, !Tv) :-
    stmt(Name ^ id_pos, A, !Tv),
    J = node("keyword", ["arg" - name_of(Name), "value" - jnull], A).

    %@helper
:- pred continuation_json(cx::in, lcco_2_1_continuation::in, jv::out,
                          tv::in, tv::out) is det.

continuation_json(Cx, cont_on(E, Body, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(action_json(Cx), Body, BodyJ, !Tv),
    J = node("OnResponse", ["test" - expr_json(Cx, E), "body" - BodyJ], A).
continuation_json(Cx, cont_timeout(E, Body, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(action_json(Cx), Body, BodyJ, !Tv),
    J = node("OnTimeout", ["duration" - expr_json(Cx, E), "body" - BodyJ], A).
continuation_json(Cx, cont_error(Code, Body, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(action_json(Cx), Body, BodyJ, !Tv),
    ( Code = yes(Ids), CodeJ = names(Ids)
    ; Code = no, CodeJ = jlist([])
    ),
    J = node("OnError", ["code" - CodeJ, "body" - BodyJ], A).

    %@helper
:- pred after_json(cx::in, ltac_2_1_after_clause::in, jv::out,
                   tv::in, tv::out) is det.

after_json(Cx, ltac_2_1_after_clause(Dur, As, Body, Nested, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(action_json(Cx), Body, BodyJ, !Tv),
    stmts(after_json(Cx), Nested, NestedJ, !Tv),
    J = node("After", ["duration" - expr_json(Cx, Dur),
        "correlation" - opt(As, expr_json(Cx)), "body" - BodyJ,
        "nested" - NestedJ], A).

%-----------------------------------------------------------------------------%
% Series, services, units
%-----------------------------------------------------------------------------%

    %@helper
:- func series_option_json(cx, lgra_7_1_block_kwarg) = jv.

series_option_json(Cx, bk_persist(E, P)) =
    node("Persist", ["duration" - expr_json(Cx, E)], short_loc(P)).
series_option_json(_, bk_by(by_name(Id), P)) =
    node("By", ["slot" - name_of(Id)], short_loc(P)).
series_option_json(_, bk_by(by_none(_), P)) =
    node("By", ["slot" - jnull], short_loc(P)).
series_option_json(Cx, bk_capacity(N, P)) =
    node("Capacity", ["samples" - span_json(Cx, "`capacity:`", [N])],
        short_loc(P)).
series_option_json(_, bk_nulls(N, P)) =
    node("Nulls", ["policy" - name_of(N)], short_loc(P)).

    %@helper
:- pred series_line_json(cx::in, lgra_7_1_series_line::in, jv::out,
                         tv::in, tv::out) is det.

series_line_json(Cx, lgra_7_1_series_line(Aggs, Time, Acc, Gap, As, P), J,
        !Tv) :-
    stmt(P, A, !Tv),
    J = node("SeriesLine", ["aggregations" - names(Aggs),
        "time" - time_json(Cx, Time), "accuracy" - opt(Acc, accuracy_json(Cx)),
        "gap" - opt(Gap, gap_json), "asname" - opt(As, name_of)], A).

    %@helper
:- func time_json(cx, lgra_7_1_time_model) = jv.

time_json(_, tm_all_time(_)) = leaf("AllTime").
time_json(Cx, tm_sliding(E, _)) = node("Sliding", ["window" - expr_json(Cx, E)],
    []).
time_json(Cx, tm_tumbling(E, _)) =
    node("Tumbling", ["window" - expr_json(Cx, E)], []).
time_json(Cx, tm_sample(E, _)) = node("Sample", ["size" - expr_json(Cx, E)], []).

    %@helper
:- func accuracy_json(cx, lgra_7_1_accuracy) = jv.

accuracy_json(_, ac_exact(_)) = leaf("Exact").
accuracy_json(Cx, ac_tolerance(E, _)) =
    node("Tolerance", ["value" - expr_json(Cx, E)], []).
accuracy_json(Cx, ac_confidence(E, _)) =
    node("Confidence", ["value" - expr_json(Cx, E)], []).
accuracy_json(Cx, ac_delta(E, _)) =
    node("Delta", ["value" - expr_json(Cx, E)], []).
accuracy_json(_, ac_bound_deterministic(_)) = leaf("BoundDeterministic").

    %@helper
:- func gap_json(lgra_7_6a_gap_policy) = jv.

gap_json(gp_hold(_)) = leaf("GapHold").
gap_json(gp_zero(_)) = leaf("GapZero").
gap_json(gp_skip(_)) = leaf("GapSkip").

    %@helper
:- pred service_kwarg_json(cx::in, service_kwarg::in, jv::out,
                           tv::in, tv::out) is det.

service_kwarg_json(Cx, service_kwarg(Name, Type, Mods, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("ServiceKwarg", ["name" - name_of(Name), "type" - name_of(Type),
        "modifiers" - jlist(list.map(kwarg_modifier_json(Cx), Mods))], A).

    %@helper
:- func kwarg_modifier_json(cx, kwarg_modifier) = jv.

kwarg_modifier_json(Cx, km_default(E, _)) =
    node("Default", ["value" - expr_json(Cx, E)], []).
kwarg_modifier_json(_, km_literal(_)) = leaf("Literal").
kwarg_modifier_json(_, km_required(_)) = leaf("Required").

    % A hydration field is statement-like but has no end location in ds.asdl.
    %
    %@helper
:- pred hydration_json(cx::in, hydration_field::in, jv::out, tv::in, tv::out)
    is det.

hydration_json(Cx, H, J, !Tv) :-
    ( H = hy_hydrates(_, P) ; H = hy_max_window(_, P)
    ; H = hy_max_limit(_, P) ; H = hy_filter_fields(_, P) ),
    stmt(P, A0, !Tv),
    A = list.filter(
        ( pred(Member::in) is semidet :-
            Member = K - _,
            K \= "end_lineno", K \= "end_col_offset" ), A0),
    (
        H = hy_hydrates(Ids, _),
        J = node("Hydrates", ["schemas" - names(Ids)], A)
    ;
        H = hy_max_window(E, _),
        J = node("MaxWindow", ["value" - expr_json(Cx, E)], A)
    ;
        H = hy_max_limit(E, _),
        J = node("MaxLimit", ["value" - expr_json(Cx, E)], A)
    ;
        H = hy_filter_fields(Fields, _),
        J = node("FilterFields",
            ["fields" - jlist(list.map(filter_field_json, Fields))], A)
    ).

    %@helper
:- func filter_field_json(filter_field) = jv.

filter_field_json(filter_field(Name, Ops, _)) =
    node("FilterField", ["name" - name_of(Name),
        "ops" - jlist(list.map(filter_op_json, Ops))], []).

    %@helper
:- func filter_op_json(filter_op) = jv.

filter_op_json(filter_op(Op, _)) = cmpop_json(Op).

    %@helper
:- pred unit_json(cx::in, luni_4_unit_decl::in, jv::out, tv::in, tv::out)
    is det.

unit_json(_, ud_dimension(Name, Storage, Base, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("UnitDimension", ["name" - name_of(Name),
        "storage" - name_of(Storage), "base" - name_of(Base)], A).
unit_json(_, ud_scalar(Name, Storage, Label, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("UnitScalar", ["name" - name_of(Name),
        "storage" - name_of(Storage), "label" - opt_str(Label)], A).
unit_json(Cx, ud_symbol(Sym, Dim, Body, Label, Aliases, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("UnitSymbol", ["symbol" - name_of(Sym),
        "dimension" - name_of(Dim), "body" - unit_body_json(Cx, Body),
        "label" - opt_str(Label), "aliases" - names(Aliases)], A).
unit_json(Cx, ud_formula(Name, Mods, Lines, P), J, !Tv) :-
    stmt(P, A, !Tv),
    stmts(formula_line_json(Cx), Lines, LinesJ, !Tv),
    J = node("UnitFormula", ["name" - name_of(Name),
        "modifiers" - jlist(list.map(formula_modifier_json, Mods)),
        "lines" - LinesJ], A).
unit_json(Cx, ud_fx_pair(Name, From, To, Via, Where, Num, Den, P), J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("UnitFxPair", ["name" - name_of(Name),
        "from_unit" - name_of(From), "to_unit" - name_of(To),
        "via" - name_of(Via), "where" - expr_json(Cx, Where),
        "numerator" - name_of(Num), "denominator" - name_of(Den)], A).

    %@helper
:- func unit_body_json(cx, luni_4_3_unit_body) = jv.

unit_body_json(_, ub_base) = leaf("BaseUnit").
unit_body_json(Cx, ub_affine(E)) = node("Affine", ["expr" - expr_json(Cx, E)],
    []).
unit_body_json(Cx, ub_tier2(luni_4_3_tier2(To, From, _))) =
    node("Tier2", ["to_base" - expr_json(Cx, To),
        "from_base" - expr_json(Cx, From)], []).

    %@helper
:- func formula_modifier_json(luni_4_5_modifier) = jv.

formula_modifier_json(fm_inverting(_)) = leaf("Inverting").
formula_modifier_json(fm_implicit(_)) = leaf("Implicit").

    %@helper
:- pred formula_line_json(cx::in, luni_4_5_formula_line::in, jv::out,
                          tv::in, tv::out) is det.

formula_line_json(Cx, luni_4_5_formula_line(Name, Param, PType, Ret, Body, P),
        J, !Tv) :-
    stmt(P, A, !Tv),
    J = node("FormulaLine", ["name" - name_of(Name), "param" - name_of(Param),
        "param_type" - name_of(PType), "returns" - name_of(Ret),
        "body" - expr_json(Cx, Body)], A).

%-----------------------------------------------------------------------------%
% Expressions
%-----------------------------------------------------------------------------%

    % A span the CST kept as tokens, parsed by the compiler's own expression
    % reader. `What` names the construct in the refusal.
    %
    %@helper
:- func span_json(cx, string, list(positioned)) = jv.

span_json(Cx, What, Span) = J :-
    lgra_9_1_parse_expr(Span, Res),
    (
        Res = ex_ok(E, _),
        J = expr_json(Cx, E)
    ;
        Res = ex_error(_, P),
        J = jbad(P, "the " ++ What ++ " is not an expression this reader "
            ++ "can parse")
    ).

    %@helper
:- func expr_json(cx, lgra_9_3_1_expr) = jv.

expr_json(Cx, E) = node(Type, Fields, expr_loc(Cx, E)) :-
    expr_fields(Cx, E, Type, Fields).

    % An `Attribute` ends where its name's token does. No other expression's end
    % is known.
    %
    %@helper
:- func expr_loc(cx, lgra_9_3_1_expr) = list(pair(string, jv)).

expr_loc(Cx, E) = Attrs :-
    Start = expr_start(E),
    ( if
        E = ex_slot(_, Attr, _),
        map.search(Cx ^ cx_tokens, Attr ^ id_pos, T)
    then
        Attrs = span_loc(Start, T ^ tk_end)
    else
        Attrs = loc(Start)
    ).

    %@helper
:- pred expr_fields(cx::in, lgra_9_3_1_expr::in, string::out,
                    list(pair(string, jv))::out) is det.

expr_fields(Cx, ex_int(I, P), "Constant",
    ["value" - jint64(I), "raw" - int_raw_at(Cx, P)]).
expr_fields(Cx, ex_float(F, P), "Constant",
    ["value" - jfloat(F), "raw" - raw_at(Cx, P)]).
expr_fields(Cx, ex_string(S, P), Type, Fields) :-
    string_fields(Cx, S, P, raw_at(Cx, P), Type, Fields).
expr_fields(Cx, ex_unit(Mag, Unit, P), "Quantity",
    ["magnitude" - jstr(Mag), "unit" - jstr(Unit), "raw" - raw_at(Cx, P)]).
expr_fields(Cx, ex_bool(B, P), "Constant",
    ["value" - jbool(B), "raw" - raw_at(Cx, P)]).
expr_fields(Cx, ex_null(P), "Constant",
    ["value" - jnull, "raw" - raw_at(Cx, P)]).
expr_fields(_, ex_name(Id), "Name", ["id" - name_of(Id)]).
expr_fields(Cx, ex_unary(Op, E, _), "UnaryOp",
    ["op" - leaf(unaryop_name(Op)), "operand" - expr_json(Cx, E)]).
expr_fields(Cx, ex_not(E, _), "UnaryOp",
    ["op" - leaf("Not"), "operand" - expr_json(Cx, E)]).
expr_fields(Cx, ex_binary(Op, L, R, _), Type, Fields) :-
    ( if boolop_name(Op, BoolName) then
        Type = "BoolOp",
        Fields = ["op" - leaf(BoolName),
            "values" - jlist(list.map(expr_json(Cx),
                bool_operands(Op, L) ++ [R]))]
    else
        Type = "BinOp",
        Fields = ["left" - expr_json(Cx, L), "op" - leaf(binop_name(Op)),
            "right" - expr_json(Cx, R)]
    ).
expr_fields(Cx, ex_compare(L, Steps, _), "Compare",
    ["left" - expr_json(Cx, L),
     "ops" - jlist(list.map(( func(S) = cmpop_json(S ^ cs_op) ), Steps)),
     "comparators" - jlist(list.map(
        ( func(S) = expr_json(Cx, S ^ cs_right) ), Steps))]).
expr_fields(Cx, ex_is(E, Neg, Subject, _), "Is",
    ["operand" - expr_json(Cx, E),
     "negated" - jbool(( if Neg = is_negated then yes else no )),
     "subject" - is_subject_json(Subject)]).
expr_fields(Cx, ex_slot(E, Attr, _), "Attribute",
    ["value" - expr_json(Cx, E), "attr" - name_of(Attr)]).
expr_fields(Cx, ex_index(E, I, _), "Subscript",
    ["value" - expr_json(Cx, E), "index" - expr_json(Cx, I)]).
expr_fields(Cx, ex_call(F, Args, _), "Call",
    ["func" - expr_json(Cx, F), "args" - jlist(list.map(expr_json(Cx), Args))]).
expr_fields(Cx, ex_cast(E, Type, Null, _), "Cast",
    ["operand" - expr_json(Cx, E), "type" - name_of(Type),
     "nullable" - nullable_json(Null)]).
expr_fields(Cx, ex_match(E, Sense, Pattern, Flags, _), "Match",
    ["operand" - expr_json(Cx, E),
     "negated" - jbool(( if Sense = ms_not_match then yes else no )),
     "pattern" - jstr(Pattern), "flags" - jstr(Flags)]).

    % `a and b and c` is one `BoolOp` with three values, as Python writes it:
    % the CST nests the chain to the left, and this flattens the left spine.
    %
    %@helper
:- func bool_operands(lgra_9_3_1_binary_op, lgra_9_3_1_expr)
    = list(lgra_9_3_1_expr).

bool_operands(Op, E) =
    ( if E = ex_binary(Op, L, R, _) then bool_operands(Op, L) ++ [R]
    else [E] ).

    %@helper
:- pred boolop_name(lgra_9_3_1_binary_op::in, string::out) is semidet.

boolop_name(bo_and, "And").
boolop_name(bo_or, "Or").

    %@helper
:- func binop_name(lgra_9_3_1_binary_op) = string.

binop_name(bo_or) = "Or".
binop_name(bo_and) = "And".
binop_name(bo_coalesce) = "Coalesce".
binop_name(bo_in) = "In".
binop_name(bo_contains) = "Contains".
binop_name(bo_overlaps) = "Overlaps".
binop_name(bo_interval) = "Range".
binop_name(bo_bitor) = "BitOr".
binop_name(bo_bitxor) = "BitXor".
binop_name(bo_bitand) = "BitAnd".
binop_name(bo_shl) = "LShift".
binop_name(bo_shr) = "RShift".
binop_name(bo_add) = "Add".
binop_name(bo_sub) = "Sub".
binop_name(bo_mul) = "Mult".
binop_name(bo_div) = "Div".
binop_name(bo_floordiv) = "FloorDiv".
binop_name(bo_mod) = "Mod".
binop_name(bo_pow) = "Pow".

    %@helper
:- func unaryop_name(lgra_9_5_1_unary_op) = string.

unaryop_name(uo_neg) = "USub".
unaryop_name(uo_pos) = "UAdd".
unaryop_name(uo_bitnot) = "Invert".

    %@helper
:- func cmpop_json(lgra_9_3_2_compare_op) = jv.

cmpop_json(co_eq) = leaf("Eq").
cmpop_json(co_ne) = leaf("NotEq").
cmpop_json(co_lt) = leaf("Lt").
cmpop_json(co_le) = leaf("LtE").
cmpop_json(co_gt) = leaf("Gt").
cmpop_json(co_ge) = leaf("GtE").

    %@helper
:- func is_subject_json(is_subject) = jv.

is_subject_json(is_null) = leaf("IsNull").
is_subject_json(is_bool(B)) = node("IsBool", ["value" - jbool(B)], []).
is_subject_json(is_inf(Sign)) =
    node("IsInf", ["negative" - jbool(( if Sign = inf_negative then yes
        else no ))], []).
is_subject_json(is_nan) = leaf("IsNaN").
is_subject_json(is_tag(Id)) = node("IsTag", ["tag" - name_of(Id)], []).

%-----------------------------------------------------------------------------%
:- end_module dsc.astjson.
%-----------------------------------------------------------------------------%

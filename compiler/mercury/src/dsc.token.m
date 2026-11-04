% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.token -- the lexical token, and source positions.
%
% `indent`, `dedent` and `newline` are produced by `dsc.layout`, never the lexer.
%-----------------------------------------------------------------------------%

:- module dsc.token.
:- interface.

:- import_module string.

%-----------------------------------------------------------------------------%
% Source positions
%-----------------------------------------------------------------------------%

    % A 1-based line and a 0-based column, in codepoints.
    %
    %@helper
:- type pos
    --->    pos(
                p_line :: int,
                p_col  :: int
            ).

    % `tk_end` is exclusive. Only a triple-quoted string ends on another line.
    %
    %@helper
:- type positioned
    --->    positioned(
                tk_tok :: token,
                tk_pos :: pos,
                tk_end :: pos
            ).

    %@helper
:- type ident
    --->    ident(
                id_name :: string,
                id_pos  :: pos
            ).

    % What identifies a dimension, a scalar group, a unit symbol or an opaque
    % type ([LUNI.4.1.5], [LOPQ.2.3]): the library declaring it, `""` for the
    % program's own file, and its `NAME`.
    %
    %@helper
:- type decl_ref
    --->    decl_ref(
                dr_file :: string,
                dr_name :: string
            ).

%-----------------------------------------------------------------------------%
% Tokens
%-----------------------------------------------------------------------------%

    %@helper
:- type token
    --->    name(string)
            % An identifier or a keyword; the parser tells them apart.

    ;       type_sym(string)
            % The [LGRA.2.5.3] terminal at every type position.

    ;       unit_suffix(string)
            % [LLEX.12.3], case sensitive. Resolving it is not the lexer's
            % ([LLEX.12.5]).

    ;       int_lit(int64)
    ;       float_lit(float)

    ;       int_min_magnitude
            % 2^63, legal only under a unary minus ([LGRA.2.7.3]).

    ;       unit_lit(string, string)
            % Numeric text and unit suffix, both unparsed.

    ;       single_str(string)
    ;       triple_str(string)
            % Raw text, delimiters removed; the consumer applies [LLEX.6.7.1].

    ;       regex_lit(string, string)
            % `/<pattern>/<flags>` as written, only right after `~` or `!~`.
            % The flags are every letter that follows.

    % -- Punctuation and operators ------------------------------------------

    ;       arrow           % ->
    ;       lparen ; rparen ; lbracket ; rbracket ; lbrace ; rbrace
    ;       comma ; dot ; dotdot ; colon ; coloncolon
    ;       question ; question2
    ;       at ; assign     % @ and a lone `=`: lexed, reserved, and refused by
                            % the parser ([LLEX.8.2.1], [LLEX.8.2.2]).
    ;       plus ; minus ; star ; star2 ; slash ; slash2 ; percent
    ;       amp ; pipe ; caret ; tilde ; shl ; shr
    ;       eq ; ne ; lt ; le ; gt ; ge
    ;       match_op ; nmatch_op    % ~ vs !~ for regex

    % -- Layout: produced by dsc.layout, never by the lexer -----------------

    ;       newline
    ;       indent
    ;       dedent.

%-----------------------------------------------------------------------------%

    %@spec [LLEX.7.5.3]
:- pred llex_7_5_3_bracket_open(token::in, token::out) is semidet.
    %@spec [LLEX.7.5.3]
:- pred llex_7_5_3_bracket_close(token::in) is semidet.

    %@helper
:- pred layout_token(token::in) is semidet.

    %@helper
:- func describe(token) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.

%-----------------------------------------------------------------------------%

llex_7_5_3_bracket_open(lparen,   rparen).
llex_7_5_3_bracket_open(lbracket, rbracket).
llex_7_5_3_bracket_open(lbrace,   rbrace).

llex_7_5_3_bracket_close(rparen).
llex_7_5_3_bracket_close(rbracket).
llex_7_5_3_bracket_close(rbrace).

layout_token(newline).
layout_token(indent).
layout_token(dedent).

%-----------------------------------------------------------------------------%

describe(name(S))            = "name `" ++ S ++ "`".
describe(type_sym(S))        = "type `" ++ S ++ "`".
describe(unit_suffix(S))     = "unit suffix `" ++ S ++ "`".
describe(int_lit(_))         = "integer literal".
describe(float_lit(_))       = "float literal".
describe(unit_lit(N, U))     = "unit literal `" ++ N ++ U ++ "`".
describe(single_str(_))      = "string literal".
describe(triple_str(_))      = "triple-quoted string".
describe(arrow)              = "`->`".
describe(lparen)             = "`(`".
describe(rparen)             = "`)`".
describe(lbracket)           = "`[`".
describe(rbracket)           = "`]`".
describe(lbrace)             = "`{`".
describe(rbrace)             = "`}`".
describe(comma)              = "`,`".
describe(dot)                = "`.`".
describe(dotdot)             = "`..`".
describe(colon)              = "`:`".
describe(coloncolon)         = "`::`".
describe(question)           = "`?`".
describe(question2)          = "`??`".
describe(at)                 = "`@`".
describe(assign)             = "`=`".
describe(plus)               = "`+`".
describe(minus)              = "`-`".
describe(star)               = "`*`".
describe(star2)              = "`**`".
describe(slash)              = "`/`".
describe(slash2)             = "`//`".
describe(percent)            = "`%`".
describe(amp)                = "`&`".
describe(pipe)               = "`|`".
describe(caret)              = "`^`".
describe(tilde)              = "`~`".
describe(shl)                = "`<<`".
describe(shr)                = "`>>`".
describe(eq)                 = "`==`".
describe(ne)                 = "`!=`".
describe(lt)                 = "`<`".
describe(le)                 = "`<=`".
describe(gt)                 = "`>`".
describe(ge)                 = "`>=`".
describe(match_op)           = "`~`".
describe(nmatch_op)          = "`!~`".
describe(regex_lit(P, F))    = "regex literal `/" ++ P ++ "/" ++ F ++ "`".
describe(int_min_magnitude)  = "integer literal `9223372036854775808`".
describe(newline)            = "end of line".
describe(indent)             = "indent".
describe(dedent)             = "dedent".

%-----------------------------------------------------------------------------%
:- end_module dsc.token.
%-----------------------------------------------------------------------------%

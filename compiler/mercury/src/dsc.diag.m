% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.diag -- the compiler's diagnostics: the carrier, its constructors, and
% the front end's own codes.
%
% The `DS_VALIDATE_*` set is `dsc.validate_codes`, generated from
% `specs/registry/validate.ebnf`. Codes are pinned; wordings are free. A live code
% may be raised nowhere yet.
%-----------------------------------------------------------------------------%
:- module dsc.diag.
:- interface.
:- import_module dsc.token.
:- import_module dsc.validate_codes.
:- import_module list.
:- import_module maybe.
:- import_module string.
%-----------------------------------------------------------------------------%
% The carrier
%-----------------------------------------------------------------------------%

    % A property of the emission, not of the code.
    %
    %@helper
:- type severity
    --->    sev_error
    ;       sev_warning.

    %@helper
:- type related
    --->    related(
                rel_pos     :: pos,
                rel_message :: string
            ).

    %@helper
:- type diag_code
    --->    dc_validate(ds_validate)
    ;       dc_front(ds_front).

    %@helper
:- func code_name(diag_code) = string.

    %@helper
:- type diagnostic
    --->    diagnostic(
                dg_code     :: diag_code,
                dg_severity :: severity,
                dg_pos      :: pos,
                dg_end      :: maybe(pos),
                    % Where the offending text ends, exclusive, when known.
                    % `no` renders as one caret.
                dg_message  :: string,
                dg_related  :: list(related),
                dg_hint     :: maybe(string),
                dg_file     :: maybe(string)
                    % The file the diagnostic is in, when it is not the input
                    % ([RCLI.1.9]). Its related spans are in the same file.
            ).

    %@helper
:- func error_at(ds_validate, pos, string) = diagnostic.

    %@helper
:- func warning_at(ds_validate, pos, string) = diagnostic.

    %@helper
:- func error_with(ds_validate, pos, string, pos, string) = diagnostic.

    %@helper
:- func with_hint(diagnostic, string) = diagnostic.

    %@helper
:- func with_end(diagnostic, pos) = diagnostic.

    % Sets `dg_file`, unless the diagnostic already names one.
    %
    %@spec [RCLI.1.9]
:- func rcli_1_9_in_file(string, diagnostic) = diagnostic.

    %@helper
:- func front_error_at(ds_front, pos, string) = diagnostic.

%-----------------------------------------------------------------------------%

    % `DS_PARSE_*` and `DS_LEX_*`: a constructor is the code minus `DS_`,
    % lowercased.
    %
    %@helper
:- type ds_front
    --->    parse_bad_escape
    ;       parse_duplicate_use
    ;       parse_dup_rate_mod
    ;       parse_expected_label
    ;       parse_float_range
    ;       parse_generic
    ;       parse_int_range
    ;       parse_kwarg_modifier_duplicate
    ;       parse_missing_colon
    ;       lex_generic
    ;       lex_invalid_identifier.

    %@helper
:- func ds_front_name(ds_front) = string.

%-----------------------------------------------------------------------------%
:- implementation.
%-----------------------------------------------------------------------------%

error_at(Code, Pos, Message) =
    diagnostic(dc_validate(Code), sev_error, Pos, no, Message, [], no, no).

warning_at(Code, Pos, Message) =
    diagnostic(dc_validate(Code), sev_warning, Pos, no, Message, [], no, no).

error_with(Code, Pos, Message, RelPos, RelMessage) =
    diagnostic(dc_validate(Code), sev_error, Pos, no, Message,
        [related(RelPos, RelMessage)], no, no).

front_error_at(Code, Pos, Message) =
    diagnostic(dc_front(Code), sev_error, Pos, no, Message, [], no, no).

with_hint(D, Hint) = D ^ dg_hint := yes(Hint).

with_end(D, End) = D ^ dg_end := yes(End).

rcli_1_9_in_file(File, D) =
    ( if D ^ dg_file = yes(_) then D else D ^ dg_file := yes(File) ).

code_name(dc_validate(Code)) = ds_validate_name(Code).
code_name(dc_front(Code)) = ds_front_name(Code).

ds_front_name(parse_bad_escape) = "DS_PARSE_BAD_ESCAPE".
ds_front_name(parse_duplicate_use) = "DS_PARSE_DUPLICATE_USE".
ds_front_name(parse_dup_rate_mod) = "DS_PARSE_DUP_RATE_MOD".
ds_front_name(parse_expected_label) = "DS_PARSE_EXPECTED_LABEL".
ds_front_name(parse_float_range) = "DS_PARSE_FLOAT_RANGE".
ds_front_name(parse_generic) = "DS_PARSE_GENERIC".
ds_front_name(parse_int_range) = "DS_PARSE_INT_RANGE".
ds_front_name(parse_kwarg_modifier_duplicate) =
    "DS_PARSE_KWARG_MODIFIER_DUPLICATE".
ds_front_name(parse_missing_colon) = "DS_PARSE_MISSING_COLON".
ds_front_name(lex_generic) = "DS_LEX_GENERIC".
ds_front_name(lex_invalid_identifier) = "DS_LEX_INVALID_IDENTIFIER".

%-----------------------------------------------------------------------------%
:- end_module dsc.diag.
%-----------------------------------------------------------------------------%

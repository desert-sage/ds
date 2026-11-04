% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.render -- diagnostics as text and as `--diagnostics json`.
%
% No clause fixes the text form. A diagnostic in the input carries no name, so the
% caller gives it.
%-----------------------------------------------------------------------------%

:- module dsc.render.
:- interface.

:- import_module dsc.diag.

:- import_module list.
:- import_module string.

    % One diagnostic as a block --
    %
    %     File "example.ds", line 4, column 18
    %         rule kitchen_motion
    %              ^^^^^^^^^^^^^^
    %     DS_PARSE_GENERIC: missing colon after rule name
    %       hint: rule headers end with `:` before the body block
    %
    % Takes the display path and the full source text.
    %
    %@helper
:- func render_diagnostic(string, string, diagnostic) = string.

    % Blank-line separated; the empty list renders as the empty string.
    %
    %@spec [RCLI.5.3]
:- func rcli_5_3_render_all(string, string, list(diagnostic)) = string.

    % One document of `compiler/dsc_diagnostics.schema.json`.
    %
    %@spec [RCLI.3.2]
:- func rcli_3_2_document(string, list(diagnostic)) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.astjson.
:- import_module dsc.token.

:- import_module int.
:- import_module maybe.

rcli_5_3_render_all(File, Source, Diags) =
    string.join_list("\n\n",
        list.map(render_diagnostic(File, Source), Diags)).

rcli_3_2_document(File, Diags) =
    "{\"diagnostics\":["
        ++ string.join_list(",", list.map(diagnostic_json(File), Diags))
        ++ "]}".

    % A missing hint is absent, never `""`.
    %
    %@helper
:- func diagnostic_json(string, diagnostic) = string.

diagnostic_json(Input, Diag) = "{" ++ string.join_list(",", Members) ++ "}" :-
    File = rcli_1_9_file(Input, Diag),
    Sev = Diag ^ dg_severity,
    (
        Sev = sev_error,
        Severity = "error"
    ;
        Sev = sev_warning,
        Severity = "warning"
    ),
    ( if Diag ^ dg_hint = yes(H), H \= "" then
        Hint = ["\"hint\":" ++ json_quote(H)]
    else
        Hint = []
    ),
    Members = [
        "\"code\":" ++ json_quote(code_name(Diag ^ dg_code)),
        "\"severity\":" ++ json_quote(Severity),
        "\"message\":" ++ json_quote(Diag ^ dg_message)
    ] ++ Hint ++ [
        "\"span\":" ++ span_json(File, Diag ^ dg_pos, Diag ^ dg_end),
        "\"related\":[" ++ string.join_list(",",
            list.map(related_json(File), Diag ^ dg_related)) ++ "]"
    ].

    %@helper
:- func related_json(string, related) = string.

related_json(File, related(Pos, Message)) =
    "{\"message\":" ++ json_quote(Message) ++ ",\"span\":"
        ++ span_json(File, Pos, no) ++ "}".

    % `end` is exclusive and 1-based; an end the diagnostic does not carry is one
    % code point on.
    %
    %@helper
:- func span_json(string, pos, maybe(pos)) = string.

span_json(File, Pos, End) =
    "{\"file\":" ++ json_quote(File) ++ ",\"start\":" ++ position_json(Start)
        ++ ",\"end\":" ++ position_json(Stop) ++ "}" :-
    Start = located(Pos),
    (
        End = yes(E),
        Stop = located(E)
    ;
        End = no,
        Stop = pos(Start ^ p_line, Start ^ p_col + 1)
    ).

    % A position as the schema counts it, 1-based. `pos(0, 0)`, given to what
    % stops before any token exists, is line 1, column 1.
    %
    %@helper
:- func located(pos) = pos.

located(pos(Line, Col)) =
    ( if Line < 1 then pos(1, 1) else pos(Line, int.max(0, Col) + 1) ).

    %@helper
:- func position_json(pos) = string.

position_json(pos(Line, Col)) =
    "{\"line\":" ++ string.from_int(Line) ++ ",\"column\":"
        ++ string.from_int(Col) ++ "}".

    %@spec [RCLI.1.9]
:- func rcli_1_9_file(string, diagnostic) = string.

rcli_1_9_file(Input, Diag) =
    ( if Diag ^ dg_file = yes(Other) then Other else Input ).

    % A diagnostic in another file is rendered without its source line: the
    % caller gives the input's text alone.
    %
render_diagnostic(Input, Source, Diag) = Text :-
    File = rcli_1_9_file(Input, Diag),
    ( if Diag ^ dg_file = yes(_) then
        Lines = []
    else
        Lines = string.split_at_char('\n', Source)
    ),
    Head = pointed_block(File, Lines, "File", Diag ^ dg_pos, Diag ^ dg_end),
    Code = [code_name(Diag ^ dg_code) ++ ": " ++ Diag ^ dg_message],
    ( if Diag ^ dg_hint = yes(H) then
        Hint = ["  hint: " ++ H]
    else
        Hint = []
    ),
    Related = list.condense(
        list.map(related_block(File, Lines), Diag ^ dg_related)),
    Text = string.join_list("\n", Head ++ Code ++ Hint ++ Related).

    %@helper
:- func related_block(string, list(string), related) = list(string).

related_block(File, Lines, related(Pos, Message)) =
    pointed_block(File, Lines, "related: File", Pos, no)
        ++ ["  " ++ Message].

    % The header, the source line, and the underline. A line out of range gets
    % the header alone.
    %
    %@helper
:- func pointed_block(string, list(string), string, pos, maybe(pos))
    = list(string).

pointed_block(File, Lines, Prefix, pos(Line, Col), End) = Block :-
    % `Col` is 0-based; a reader sees 1-based columns.
    Header = string.format("%s \"%s\", line %d, column %d",
        [s(Prefix), s(File), i(Line), i(Col + 1)]),
    ( if
        Line >= 1,
        list.index1(Lines, Line, Src)
    then
        Block = [Header, "    " ++ Src,
            "    " ++ underline(Src, Line, Col, End)]
    else
        Block = [Header]
    ).

    % Width is floored at one. A span that leaves the line is clipped to it, and
    % a note says where it ends.
    %
    %@helper
:- func underline(string, int, int, maybe(pos)) = string.

underline(Src, Line, Col, End) = Pad ++ Carets ++ Note :-
    Pad = string.duplicate_char(' ', int.max(0, Col)),
    (
        End = no,
        Carets = "^",
        Note = ""
    ;
        End = yes(pos(EndLine, EndCol)),
        ( if EndLine = Line then
            Carets = string.duplicate_char('^', int.max(1, EndCol - Col)),
            Note = ""
        else
            Carets = string.duplicate_char('^',
                int.max(1, string.count_codepoints(Src) - Col)),
            Note = string.format(
                " (continues to line %d, column %d)",
                [i(EndLine), i(EndCol + 1)])
        )
    ).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.yaml -- the subset of YAML a dialect file is written in, and no more.
%
% Reads top-level `key: scalar`, `key:` followed by `- item` lines or by one level
% of indented `name: scalar` lines, and a flow list `key: [a, b]`. Anything else
% is refused with its line, a key given twice included. Every file this accepts
% reads the same under YAML 1.1.
%-----------------------------------------------------------------------------%

:- module dsc.yaml.
:- interface.

:- import_module list.

%-----------------------------------------------------------------------------%

    %@helper
:- type yaml_value
    --->    yv_null
            % `key:` with nothing under it, or `~` / `null`.
    ;       yv_string(string)
    ;       yv_other(string)
            % A plain scalar YAML reads as a bool or a number.
    ;       yv_list(list(yaml_value))
    ;       yv_map(list(yaml_entry)).
            % One level of indented `name: scalar` lines, in file order. Its
            % values are scalars: a further level is refused.

    %@helper
:- type yaml_entry
    --->    yaml_entry(
                ye_key   :: string,
                ye_line  :: int,
                ye_value :: yaml_value
            ).

    %@helper
:- type yaml_result
    --->    yaml_ok(list(yaml_entry))
            % The top-level mapping, in file order.
    ;       yaml_error(int, string).
            % The 1-based line, and why it is outside the subset.

    %@helper
:- pred read_mapping(string::in, yaml_result::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module maybe.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

    %@helper
:- type state
    --->    at_top
    ;       in_items(
                ii_key    :: string,
                ii_line   :: int,
                ii_indent :: maybe(int),
                    % The first item's indentation.
                ii_items  :: list(yaml_value)
                    % Reversed.
            )
    ;       in_map(
                im_key     :: string,
                im_line    :: int,
                im_indent  :: int,
                im_entries :: list(yaml_entry),
                    % Reversed.
                im_keys    :: set(string)
            ).

    %@helper
:- type acc
    --->    acc(
                a_state   :: state,
                a_entries :: list(yaml_entry),
                    % Reversed.
                a_keys    :: set(string),
                a_seen    :: bool
                    % Whether any content line has been read: `---` is admitted
                    % only before one.
            ).

read_mapping(Text, Result) :-
    Lines = string.split_at_char('\n', Text),
    read_lines(Lines, 1, acc(at_top, [], set.init, no), Result).

    %@helper
:- pred read_lines(list(string)::in, int::in, acc::in, yaml_result::out)
    is det.

read_lines([], _, Acc, Result) :-
    Entries = finish(Acc ^ a_state, Acc ^ a_entries),
    Result = yaml_ok(list.reverse(Entries)).
read_lines([Raw | Rest], N, Acc0, Result) :-
    read_line(Raw, N, Acc0, LineResult),
    (
        LineResult = line_ok(Acc),
        read_lines(Rest, N + 1, Acc, Result)
    ;
        LineResult = line_error(Why),
        Result = yaml_error(N, Why)
    ).

    %@helper
:- func finish(state, list(yaml_entry)) = list(yaml_entry).

finish(at_top, Entries) = Entries.
finish(in_map(Key, Line, _, RevEntries, _), Entries) =
    [yaml_entry(Key, Line, yv_map(list.reverse(RevEntries))) | Entries].
finish(in_items(Key, Line, _, RevItems), Entries) = [Entry | Entries] :-
    (
        RevItems = [],
        Value = yv_null
    ;
        RevItems = [_ | _],
        Value = yv_list(list.reverse(RevItems))
    ),
    Entry = yaml_entry(Key, Line, Value).

    %@helper
:- type line_result
    --->    line_ok(acc)
    ;       line_error(string).

    %@helper
:- pred read_line(string::in, int::in, acc::in, line_result::out) is det.

read_line(Raw0, N, Acc0, Result) :-
    ( if string.remove_suffix(Raw0, "\r", Raw1) then
        Raw = Raw1
    else
        Raw = Raw0
    ),
    Chars = string.to_char_list(Raw),
    list.take_while(char.is_whitespace, Chars, Leading, _),
    ( if list.member('\t', Leading) then
        Result = line_error("a tab in the indentation; YAML indents with "
            ++ "spaces")
    else
        Content = string.strip(strip_comment(Raw)),
        Indent = list.length(Leading),
        ( if Content = "" then
            Result = line_ok(Acc0)
        else if Content = "---", Acc0 ^ a_seen = no then
            Acc = Acc0 ^ a_seen := yes,
            Result = line_ok(Acc)
        else if is_item(Content, ItemText) then
            read_item(ItemText, Indent, Acc0, Result)
        else if Indent > 0 then
            read_map_line(Content, N, Indent, Acc0, Result)
        else
            read_key(Content, N, Acc0, Result)
        )
    ).

    %@helper
:- pred is_item(string::in, string::out) is semidet.

is_item(Content, Item) :-
    ( if Content = "-" then
        Item = ""
    else
        string.remove_prefix("- ", Content, Item0),
        Item = string.strip(Item0)
    ).

    %@helper
:- pred read_item(string::in, int::in, acc::in, line_result::out) is det.

read_item(ItemText, Indent, Acc0, Result) :-
    State0 = Acc0 ^ a_state,
    (
        State0 = at_top,
        Result = line_error("a `- item` with no `key:` above it")
    ;
        State0 = in_map(Key, _, _, _, _),
        Result = line_error("a `- item` among the `name: value` lines of `"
            ++ Key ++ "`")
    ;
        State0 = in_items(Key, Line, MaybeIndent, RevItems),
        ( if MaybeIndent = yes(I), I \= Indent then
            Result = line_error("list items of `" ++ Key ++ "` at two "
                ++ "different indentations")
        else
            scalar(ItemText, ScalarRes),
            (
                ScalarRes = val_ok(Value),
                State = in_items(Key, Line, yes(Indent), [Value | RevItems]),
                Acc = acc(State, Acc0 ^ a_entries, Acc0 ^ a_keys, yes),
                Result = line_ok(Acc)
            ;
                ScalarRes = val_error(Why),
                Result = line_error(Why)
            )
        )
    ).

    %@helper
:- pred read_map_line(string::in, int::in, int::in, acc::in, line_result::out)
    is det.

read_map_line(Content, N, Indent, Acc0, Result) :-
    State0 = Acc0 ^ a_state,
    ( if
        ( State0 = in_items(Key, Line, no, []),
            RevEntries = [], Keys = set.init, Indent0 = Indent
        ; State0 = in_map(Key, Line, Indent0, RevEntries, Keys)
        )
    then
        ( if Indent \= Indent0 then
            Result = line_error("lines of `" ++ Key ++ "` at two different "
                ++ "indentations; this reader accepts one level of nesting")
        else if split_key(Content, Name, ValueText) then
            ( if set.contains(Keys, Name) then
                Result = line_error("`" ++ Name ++ "` is given twice under `"
                    ++ Key ++ "`")
            else if ValueText = "" then
                Result = line_error("`" ++ Name ++ "` under `" ++ Key ++ "` "
                    ++ "has no value; this reader accepts one level of "
                    ++ "nesting")
            else
                scalar(ValueText, ScalarRes),
                (
                    ScalarRes = val_ok(Value),
                    State = in_map(Key, Line, Indent0,
                        [yaml_entry(Name, N, Value) | RevEntries],
                        set.insert(Keys, Name)),
                    Result = line_ok(acc(State, Acc0 ^ a_entries,
                        Acc0 ^ a_keys, yes))
                ;
                    ScalarRes = val_error(Why),
                    Result = line_error(Why)
                )
            )
        else
            Result = line_error("expected `name: value`")
        )
    else
        Result = line_error("an indented line that is not a `- item` or a "
            ++ "`name: value` line directly under an empty `key:`")
    ).

    %@helper
:- pred read_key(string::in, int::in, acc::in, line_result::out) is det.

read_key(Content, N, Acc0, Result) :-
    ( if split_key(Content, Key, ValueText) then
        Entries0 = finish(Acc0 ^ a_state, Acc0 ^ a_entries),
        ( if set.contains(Acc0 ^ a_keys, Key) then
            Result = line_error("`" ++ Key ++ "` is given twice")
        else if ValueText = "" then
            Acc = acc(in_items(Key, N, no, []), Entries0,
                set.insert(Acc0 ^ a_keys, Key), yes),
            Result = line_ok(Acc)
        else
            value(ValueText, ValueRes),
            (
                ValueRes = val_ok(Value),
                Acc = acc(at_top, [yaml_entry(Key, N, Value) | Entries0],
                    set.insert(Acc0 ^ a_keys, Key), yes),
                Result = line_ok(Acc)
            ;
                ValueRes = val_error(Why),
                Result = line_error(Why)
            )
        )
    else
        Result = line_error("expected `key: value`")
    ).

    %@helper
:- pred split_key(string::in, string::out, string::out) is semidet.

split_key(Content, Key, Value) :-
    ( if string.sub_string_search(Content, ": ", Ix) then
        Key = string.left(Content, Ix),
        Value = string.strip(string.right(Content,
            string.length(Content) - Ix - 2))
    else
        string.remove_suffix(Content, ":", Key),
        Value = ""
    ),
    Key \= "",
    string.all_match(is_key_char, Key).

    %@helper
:- pred is_key_char(char::in) is semidet.

is_key_char(C) :-
    ( char.is_alnum_or_underscore(C) ; C = ('-') ).

    %@helper
:- type value_result
    --->    val_ok(yaml_value)
    ;       val_error(string).

    %@helper
:- pred value(string::in, value_result::out) is det.

value(Text, Result) :-
    ( if string.remove_prefix("[", Text, AfterOpen) then
        ( if string.remove_suffix(AfterOpen, "]", Inner) then
            flow_list(string.strip(Inner), Result)
        else
            Result = val_error("a flow list must open and close on one line")
        )
    else
        scalar(Text, Result)
    ).

    %@helper
:- pred flow_list(string::in, value_result::out) is det.

flow_list(Inner, Result) :-
    ( if Inner = "" then
        Result = val_ok(yv_list([]))
    else if
        ( string.contains_char(Inner, '"')
        ; string.contains_char(Inner, '\'')
        ; string.contains_char(Inner, '[')
        ; string.contains_char(Inner, '{')
        )
    then
        Result = val_error("a flow list here holds plain words only; use "
            ++ "`- item` lines for anything quoted or nested")
    else
        Parts = list.map(string.strip, string.split_at_char(',', Inner)),
        flow_items(Parts, [], Result)
    ).

    %@helper
:- pred flow_items(list(string)::in, list(yaml_value)::in, value_result::out)
    is det.

flow_items([], RevItems, val_ok(yv_list(list.reverse(RevItems)))).
flow_items([Part | Parts], RevItems, Result) :-
    ( if Part = "" then
        Result = val_error("an empty entry in a flow list")
    else
        scalar(Part, ScalarRes),
        (
            ScalarRes = val_ok(Value),
            flow_items(Parts, [Value | RevItems], Result)
        ;
            ScalarRes = val_error(Why),
            Result = val_error(Why)
        )
    ).

    %@helper
:- pred scalar(string::in, value_result::out) is det.

scalar(Text, Result) :-
    ( if Text = "" then
        Result = val_ok(yv_null)
    else if string.remove_prefix("\"", Text, AfterOpen) then
        ( if
            string.remove_suffix(AfterOpen, "\"", Inner),
            not string.contains_char(Inner, '"'),
            not string.contains_char(Inner, '\\')
        then
            Result = val_ok(yv_string(Inner))
        else
            Result = val_error("a double-quoted scalar must close on its "
                ++ "line and carry no escape")
        )
    else if string.remove_prefix("'", Text, AfterOpen) then
        ( if
            string.remove_suffix(AfterOpen, "'", Inner),
            not string.contains_char(Inner, '\'')
        then
            Result = val_ok(yv_string(Inner))
        else
            Result = val_error("a single-quoted scalar must close on its "
                ++ "line and carry no `''`")
        )
    else if
        string.index(Text, 0, First),
        string.contains_char("[]{},&*!|>%@`?", First)
    then
        Result = val_error("`" ++ Text ++ "` starts with a YAML indicator "
            ++ "this reader does not support")
    else if
        ( string.sub_string_search(Text, ": ", _)
        ; string.suffix(Text, ":")
        )
    then
        Result = val_error("a nested mapping; this reader accepts top-level "
            ++ "`key: value` and lists of strings only")
    else if null_word(Text) then
        Result = val_ok(yv_null)
    else if ( bool_word(Text) ; number_like(Text) ) then
        Result = val_ok(yv_other(Text))
    else
        Result = val_ok(yv_string(Text))
    ).

    %@helper
:- pred null_word(string::in) is semidet.

null_word("~").
null_word("null").
null_word("Null").
null_word("NULL").

    % YAML 1.1's booleans.
    %
    %@helper
:- pred bool_word(string::in) is semidet.

bool_word(W) :-
    list.member(W, ["yes", "Yes", "YES", "no", "No", "NO",
        "true", "True", "TRUE", "false", "False", "FALSE",
        "on", "On", "ON", "off", "Off", "OFF"]).

    % Wider than YAML's own resolver: the caller asks for quotes.
    %
    %@helper
:- pred number_like(string::in) is semidet.

number_like(Text) :-
    ( if
        ( string.remove_prefix("-", Text, Unsigned)
        ; string.remove_prefix("+", Text, Unsigned)
        )
    then
        Body = Unsigned
    else
        Body = Text
    ),
    string.index(Body, 0, First),
    ( char.is_digit(First) ; First = ('.') ),
    string.all_match(is_number_char, Body).

    %@helper
:- pred is_number_char(char::in) is semidet.

is_number_char(C) :-
    ( char.is_hex_digit(C)
    ; string.contains_char("._:+-xXoObBiInNfFaA", C)
    ).

    % A `#` starts a comment at the start of the line or after a space, never
    % inside quotes.
    %
    %@helper
:- func strip_comment(string) = string.

strip_comment(Line) =
    string.from_char_list(before_comment(string.to_char_list(Line), no, ' ')).

    %@helper
:- func before_comment(list(char), maybe(char), char) = list(char).

before_comment([], _, _) = [].
before_comment([C | Cs], Quote, Prev) = Out :-
    (
        Quote = yes(Q),
        ( if C = Q then Quote1 = no else Quote1 = Quote ),
        Out = [C | before_comment(Cs, Quote1, C)]
    ;
        Quote = no,
        ( if C = '#', char.is_whitespace(Prev) then
            Out = []
        else if ( C = '"' ; C = '\'' ) then
            Out = [C | before_comment(Cs, yes(C), C)]
        else
            Out = [C | before_comment(Cs, no, C)]
        )
    ).

%-----------------------------------------------------------------------------%
:- end_module dsc.yaml.
%-----------------------------------------------------------------------------%

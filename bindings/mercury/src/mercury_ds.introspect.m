%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.introspect.m.
%
% What a host can read about a session's program and state: its rules and
% where they are declared, its source, the justifications of a fact, a
% fact's path through the network and the matches refraction holds back, and
% the artefact's header.
%
% No series read: no public function reads a series ([NSBK.6.3]). A
% rule reads one, and what it does is what the host sees.
%
% Every read is a function of the session, so it changes nothing and takes
% no `io` (MER.7).
%
% Every read answers `halted` once the session's engine has halted, as
% `mercury_ds.session`'s do ([NCBK.2.9]): the
% engine state and the loaded program alike, as libds refuses
% `ds_engine_rule_meta_*`, `ds_engine_ds_source_*`, `ds_engine_line_span_*`
% and the NDBG reads. A search fails only for "not found", and answers
% `halted` whatever its key. `proto_text` takes a schema, which only a read
% that refuses hands out.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.introspect.
:- interface.

:- import_module mercury_ds.session.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.engine.
:- import_module ds.id.
:- import_module ds.schema.
:- import_module ds.service.
:- import_module list.
:- import_module maybe.

%---------------------------------------------------------------------------%
% Schemas and services
%---------------------------------------------------------------------------%

    % The `.proto` text the compiler generated from a schema's declaration
    % ([RDSC.5.8]), or `no` where the artefact carries none.
    %
:- func proto_text(schema) = maybe(string).

    % Where the schema of this name is declared ([RDSC.5.7]).
    % `search_schema_source` fails if the artefact does not say: for a
    % builtin schema, a name no schema has, and
    % every schema of an artefact compiled without source positions.
    % `lookup_schema_source` throws an exception instead.
    %
:- pred search_schema_source(session::in, string::in, read(source_loc)::out)
    is semidet.
:- func lookup_schema_source(session, string) = read(source_loc).

    % A service the program declares.
    %
:- type service_info
    --->    service_info(
                service_info_name     :: string,
                            % Its name, `domain.method`.
                service_info_response :: maybe(string),
                            % The schema it answers with ([LADP.8.4.2]), or
                            % `no` for a service declared `no response`
                            % ([LCRS.17.1]).
                service_info_kwargs   :: list(service_kwarg)
                            % The kwargs it declares, in name order, as the
                            % runtime's `ds.service.service_kwarg`: each
                            % one's type name, whether a call must supply
                            % it and as a literal, and its default. An
                            % artefact whose kwargs do not decode does not
                            % load ([RDSC.11.1]).
            ).

    % The services the program declares, in artefact order.
    %
:- func services(session) = read(list(service_info)).

%---------------------------------------------------------------------------%
% Rules
%---------------------------------------------------------------------------%

:- type rule_info
    --->    rule_info(
                rule_info_name     :: string,
                rule_info_cooldown :: maybe(duration),
                            % `no` for a rule with no cooldown.
                rule_info_display  :: maybe(string),
                            % The template a firing's display name is built
                            % from.
                rule_info_source   :: maybe(source_loc)
                            % Where the rule is declared, `no` when the
                            % artefact does not say.
            ).

    % A position in a module's DS source.
    %
:- type source_loc
    --->    source_loc(
                source_loc_file   :: maybe(string),
                            % The module's display path, or `no` when the
                            % artefact carries no source for the module.
                source_loc_line   :: int,
                            % From 1.
                source_loc_column :: int
                            % From 1.
            ).

    % Every rule, in the order the agenda ranks them.
    %
:- func rules(session) = read(list(rule_info)).

    % The rule of this name. `search_rule` fails if there is none;
    % `lookup_rule` throws an exception.
    %
:- pred search_rule(session::in, string::in, read(rule_info)::out)
    is semidet.
:- func lookup_rule(session, string) = read(rule_info).

%---------------------------------------------------------------------------%
% Source
%---------------------------------------------------------------------------%

    % Each module's DS source text, in artefact order ([RDSC.14.2]).
    %
:- func sources(session) = read(list(ds_source)).

    % The source position of each network node the artefact gives one, in
    % artefact order ([RDSC.14.3]). An alpha carries none, and neither does a
    % node the compiler makes for itself ([RDSC.14.3.6]).
    %
:- func line_spans(session) = read(list(line_span)).

    % The source position of the node with this id: what a fault's node
    % names. `search_line_span` fails if no span names the node;
    % `lookup_line_span` throws an exception.
    %
:- pred search_line_span(session::in, uint32::in, read(line_span)::out)
    is semidet.
:- func lookup_line_span(session, uint32) = read(line_span).

    % The display path of the module with this `module_id`.
    % `search_source_file` fails if the artefact carries no source for it;
    % `lookup_source_file` throws an exception.
    %
:- pred search_source_file(session::in, uint32::in, read(string)::out)
    is semidet.
:- func lookup_source_file(session, uint32) = read(string).

%---------------------------------------------------------------------------%
% Truth maintenance
%---------------------------------------------------------------------------%

    % One live activation that supports a logical fact.
    %
:- type justifier
    --->    justifier(
                justifier_rule    :: string,
                justifier_timetag :: maybe(timetag)
                            % `no`: the runtime keeps the rule, not the
                            % firing.
            ).

    % The live justifications of a fact, one for each activation that
    % supports it; none for a fact not asserted `logical`.
    %
:- func justifiers(session, fact_id) = read(list(justifier)).

%---------------------------------------------------------------------------%
% The network
%---------------------------------------------------------------------------%

    % A live fact's path through the alpha nodes that test its schema, in
    % the order they test it, each step passed or filtered ([NDBG.4.2]).
    % None for an id no live fact has.
    %
:- func match_trace(session, fact_id) = read(list(trace_step)).

    % The matches that have fired and are held back from firing again
    % ([NDBG.4.3]), for every rule (`no`) or for the one named, rule by rule
    % in their order.
    %
:- func refracted_activations(session, maybe(string))
    = read(list(refracted_activation)).

%---------------------------------------------------------------------------%
% The artefact
%---------------------------------------------------------------------------%

    % The artefact's header: its version, hashes and bindings.
    %
:- func artefact_header(session) = read(dsc_header).

    % No canonical contract: libds.h declares none of realtime's entry points
    % ([NRTM.9.1]). The runtime's ds.contract keeps the serializer the load
    % path's hash check uses.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module ds.intern.
:- import_module ds.rules.
:- import_module ds.tms.
:- import_module bool.
:- import_module string.
:- import_module uint32.

    % Qualified: `error/1` is also `maybe_error`'s failure, so the throw is
    % written `require.error`.
    %
:- use_module require.

%---------------------------------------------------------------------------%

    % [NCBK.2.9]: a read is refused once the
    % engine has halted, decided by the latch alone, as `mercury_ds.session`'s
    % `reading` decides it. The value is a closure so that nothing reads the
    % halted session to build an answer no one gets.
    %
:- func reading(session, (func) = T) = read(T).

reading(S, Value) = Read :-
    ( if halted(S) = yes(Error) then
        Read = halted(Error)
    else
        Read = ok(apply(Value))
    ).

    % A search's answer: `halted` whatever the key once the latch is set,
    % else the value `Search` finds, failing where it finds none.
    %
:- pred searching(session::in, pred(T)::(pred(out) is semidet),
    read(T)::out) is semidet.

searching(S, Search, Read) :-
    ( if halted(S) = yes(Error) then
        Read = halted(Error)
    else
        Search(Value),
        Read = ok(Value)
    ).

proto_text(Schema) = maybe.map_maybe(proto_source_text, Schema ^ s_proto).

search_schema_source(S, Name, Read) :-
    searching(S,
        ( pred(Loc::out) is semidet :-
            P = session_program(S),
            ds.dsc.schema_source_for(P, Name, Pos),
            Loc = source_loc_of(P, Pos)
        ), Read).

lookup_schema_source(S, Name) = Read :-
    ( if search_schema_source(S, Name, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.introspect.lookup_schema_source: no "
            ++ "position for schema " ++ Name)
    ).

services(S) = reading(S, (func) = list.map(service_info_of,
        declared_services(session_program(S)))).

    % The runtime's [NDBG.2.4] view, one per ServiceDef in artefact order.
    % `no response` is the runtime's flag, not an empty response read as one.
    %
:- func service_info_of(svcd) = service_info.

service_info_of(Svc) = service_info(Svc ^ sv_name,
    ( if Svc ^ sv_no_response = yes then no else yes(Svc ^ sv_response) ),
    Svc ^ sv_kwargs).

%---------------------------------------------------------------------------%

rules(S) = reading(S, (func) = all_rules(S)).

:- func all_rules(session) = list(rule_info).

all_rules(S) = list.map(rule_info_of(P, Interns), rule_metas(P)) :-
    P = session_program(S),
    Interns = engine_interns(session_engine(S)).

search_rule(S, Name, Read) :-
    searching(S,
        ( pred(Info::out) is semidet :-
            list.find_first_match(rule_named(Name), all_rules(S), Info)
        ), Read).

lookup_rule(S, Name) = Read :-
    ( if search_rule(S, Name, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.introspect.lookup_rule: no rule named " ++
            Name)
    ).

:- pred rule_named(string::in, rule_info::in) is semidet.

rule_named(Name, Info) :-
    Info ^ rule_info_name = Name.

:- func rule_info_of(program, intern_table, rule_meta) = rule_info.

rule_info_of(P, Interns, M) =
    rule_info(text_of(Interns, M ^ rm_name), M ^ rm_rate ^ rc_cooldown,
        M ^ rm_display, maybe.map_maybe(source_loc_of(P), M ^ rm_where)).

    % The runtime's position names its module by `module_id`. A position whose
    % module the artefact carries no source for keeps its line and column,
    % as libds answers a NULL file with the line and column it has.
    %
:- func source_loc_of(program, source_pos) = source_loc.

source_loc_of(P, source_pos(Line, Col, Clip)) =
        source_loc(File, uint32.cast_to_int(Line), uint32.cast_to_int(Col)) :-
    ( if ds.dsc.source_file(P, Clip, Path) then
        File = yes(Path)
    else
        File = no
    ).

%---------------------------------------------------------------------------%

sources(S) = reading(S, (func) = ds.dsc.sources(session_program(S))).

line_spans(S) = reading(S, (func) = ds.dsc.line_spans(session_program(S))).

search_line_span(S, Node, Read) :-
    searching(S,
        ( pred(Span::out) is semidet :-
            ds.dsc.line_span_for(session_program(S), Node, Span)
        ), Read).

lookup_line_span(S, Node) = Read :-
    ( if search_line_span(S, Node, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.introspect.lookup_line_span: no span "
            ++ "names node " ++ uint32_to_string(Node))
    ).

search_source_file(S, Clip, Read) :-
    searching(S,
        ( pred(File::out) is semidet :-
            ds.dsc.source_file(session_program(S), Clip, File)
        ), Read).

lookup_source_file(S, Clip) = Read :-
    ( if search_source_file(S, Clip, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.introspect.lookup_source_file: no source "
            ++ "for clip " ++ uint32_to_string(Clip))
    ).

%---------------------------------------------------------------------------%

justifiers(S, Id) = reading(S, (func) = all_justifiers(S, Id)).

:- func all_justifiers(session, fact_id) = list(justifier).

all_justifiers(S, Id) = list.map(justifier_of(Metas, Interns), Terminals) :-
    E = session_engine(S),
    Interns = engine_interns(E),
    Metas = rule_metas(session_program(S)),
    Terminals = justifying_terminals(engine_tms(E), Id).

:- func justifier_of(list(rule_meta), intern_table, uint32) = justifier.

justifier_of(Metas, Interns, Terminal) = justifier(Name, no) :-
    ( if list.find_first_match(terminal_is(Terminal), Metas, M) then
        Name = text_of(Interns, M ^ rm_name)
    else
        Name = ""
    ).

:- pred terminal_is(uint32::in, rule_meta::in) is semidet.

terminal_is(Terminal, M) :-
    node_id_value(M ^ rm_terminal) = Terminal.

%---------------------------------------------------------------------------%

match_trace(S, Id) =
    reading(S, (func) = engine_rete_match_trace(session_engine(S), Id)).

refracted_activations(S, Rule) =
    reading(S,
        (func) = engine_refracted_activations(session_engine(S), Rule)).

%---------------------------------------------------------------------------%

artefact_header(S) = reading(S, (func) = header(session_program(S))).

%---------------------------------------------------------------------------%

:- func text_of(intern_table, intern_ref) = string.

text_of(Interns, Ref) =
    ( if expand(Interns, Ref, String) then String else "" ).

%---------------------------------------------------------------------------%

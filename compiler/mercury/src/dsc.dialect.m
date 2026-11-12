% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.dialect -- dialects, a program's `use` line, and the constructs its
% resolved settings permit.
%
% Nothing here resolves an absent `use` line: `dsc.driver` refuses a library given
% to build ([LDIA.2.10.8]).
%-----------------------------------------------------------------------------%

:- module dsc.dialect.
:- interface.

:- import_module ds.
:- import_module ds.capability.
:- import_module dsc.ast.
:- import_module dsc.capability.
:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.resolve.
:- import_module dsc.token.
:- import_module dsc.yaml.

:- import_module list.
:- import_module map.

%-----------------------------------------------------------------------------%

    %@helper
:- type dialect
    --->    dialect(
                dl_name     :: string,
                dl_settings :: settings
            ).

    %@helper
:- type registry == map(string, dialect).

    %@spec [LDIA.9]
:- func builtin_registry = registry.

%-----------------------------------------------------------------------------%
% A dialect file -- [NDLC.2]
%-----------------------------------------------------------------------------%

    % A dialect as its file defines it, before registration has checked it.
    %
    %@helper
:- type dialect_def
    --->    dialect_def(
                dd_name     :: string,
                dd_settings :: list(yaml_entry)
            ).

    %@helper
:- type definition_result
    --->    definition(dialect_def)
    ;       definition_refused(string).
            % Worded for the caller to prefix with the file's path.

    %@spec [NDLC.2.1]
:- pred ndlc_2_1_definition(list(yaml_entry)::in, definition_result::out)
    is det.

    %@helper
:- type registration
    --->    registered(registry)
    ;       registration_refused(ds_validate, string).

    % The checks run in [NDLC.6.1]'s order.
    %
    %@spec [NDLC.2.2]
    %@spec [NDLC.6.1]
:- pred ndlc_2_2_register(dialect_def::in, registry::in, registration::out)
    is det.

%-----------------------------------------------------------------------------%
% The program's `use` line -- [LDIA.3]
%-----------------------------------------------------------------------------%

    %@helper
:- type resolution
    --->    resolved(program_settings)
    ;       resolution_refused(list(diagnostic)).

    % [LDIA.3.1]'s first three checks; `ldia_3_4_1_gate` is the fourth. A step
    % that fails stops the steps after it.
    %
    %@spec [LDIA.3.1]
:- pred ldia_3_1_resolve(registry::in, ast_use::in, resolution::out) is det.

    %@spec [LDIA.3.4.1]
    %@spec [LDIA.3.4.2]
:- func ldia_3_4_1_gate(resolved_file) = list(diagnostic).

    % For a check that is not a plain use site: `retain:`, whose exemption
    % ([LDTL.3.2]) `dsc.validate` decides.
    %
    %@spec [LDIA.3.4.2]
:- func ldia_5_1_disabled_at(program_settings, capability, string, pos)
    = diagnostic.

    % A construct capability is needed when a construct it governs is present.
    % [RDSC.16.2.8] does not say what a strategy capability needs, so: `realtime`
    % and `constspace` when `true`, `linear_scan` never, and `dynamic_ttl` when
    % `true` with a `retain:` present.
    %
    %@spec [RDSC.16.2.8]
:- func rdsc_16_2_8_requires(program_settings, list(resolved_file))
    = settings.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module dsc.expr.
:- import_module dsc.layout.
:- import_module dsc.lex.
:- import_module dsc.types.

:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%
% The built-in dialects -- [LDIA.9]
%-----------------------------------------------------------------------------%

builtin_registry = map.from_assoc_list([
    "base" - dialect("base", set.init),
    "default" - dialect("default", ldia_9_2_default),
    "realtime" - dialect("realtime",
        set.insert_list(ldia_9_2_default, [cap_realtime, cap_constspace]))]).

    %@spec [LDIA.9.2]
:- func ldia_9_2_default = settings.

ldia_9_2_default = set.delete_list(set.list_to_set(all_capabilities),
    [cap_realtime, cap_constspace, cap_dynamic_ttl] ++ lcap_2_10_deferred).

    % Deferred: every check gated on these stays in the tree, unreachable.
    %
    %@spec [LCAP.2.10]
:- func lcap_2_10_deferred = list(capability).

lcap_2_10_deferred = [cap_sampled_slots, cap_persist_on_series,
    cap_storage_hydrate_facts, cap_storage_hydrate_samples].

    %@spec [LCAP.2.10]
:- func lcap_2_10_deferred_on(settings) = list(capability).

lcap_2_10_deferred_on(Settings) =
    list.filter((pred(C::in) is semidet :- set.contains(Settings, C)),
        lcap_2_10_deferred).

    % Deferred: the `realtime` dialect stays registered, and every check gated on
    % these stays in the tree, unreachable.
    %
    %@spec [LCAP.2.1.5]
:- func lcap_2_1_5_deferred_on(settings) = list(capability).

lcap_2_1_5_deferred_on(Settings) =
    list.filter((pred(C::in) is semidet :- set.contains(Settings, C)),
        [cap_realtime, cap_constspace]).

%-----------------------------------------------------------------------------%
% A dialect file -- [NDLC.2]
%-----------------------------------------------------------------------------%

ndlc_2_1_definition(Entries, Result) :-
    ( if
        list.find_first_match(
            ( pred(E::in) is semidet :-
                E ^ ye_key \= "name", E ^ ye_key \= "settings" ),
            Entries, Unknown)
    then
        Result = definition_refused("line " ++ string.from_int(
            Unknown ^ ye_line) ++ ": `" ++ Unknown ^ ye_key ++ "` is not a "
            ++ "dialect field; a dialect is `name` and `settings` "
            ++ "([NDLC.2.1])")
    else if
        entry_value(Entries, "settings", yv_map(Settings))
    then
        Result = definition(dialect_def(name_text(Entries), Settings))
    else
        Result = definition_refused("`settings` must be a mapping with a "
            ++ "`true` or `false` line for every capability ([NDLC.2.2])")
    ).

    % A missing, empty or non-scalar `name` is "", for registration to refuse.
    %
    %@helper
:- func name_text(list(yaml_entry)) = string.

name_text(Entries) = Name :-
    ( if
        entry_value(Entries, "name", Value),
        ( Value = yv_string(Name0)
        ; Value = yv_other(Name0)
        )
    then
        Name = Name0
    else
        Name = ""
    ).

    % It lexes, alone, to one `NAME` token whose text is the name itself, so it
    % is already NFC.
    %
    %@spec [NDLC.6.1]
:- pred ndlc_6_1_nameable(string::in) is semidet.

ndlc_6_1_nameable(Name) :-
    llex_5_4_lex(Name ++ "\n", lex_ok([source_line(_, [Tok])])),
    Tok ^ tk_tok = name(Name).

    %@helper
:- pred entry_value(list(yaml_entry)::in, string::in, yaml_value::out)
    is semidet.

entry_value(Entries, Key, Value) :-
    list.find_first_match((pred(E::in) is semidet :- E ^ ye_key = Key),
        Entries, Entry),
    Value = Entry ^ ye_value.

ndlc_2_2_register(dialect_def(Name, Lines), Registry, Result) :-
    % Predicate calls: five function applications of these overloaded names pass
    % the type checker's limit.
    list.filter(
        ( pred(L::in) is semidet :- not capability_named(L ^ ye_key, _) ),
        Lines, Unknown),
    list.filter_map(
        ( pred(L::in, C::out) is semidet :- capability_named(L ^ ye_key, C) ),
        Lines, Named),
    list.filter(
        ( pred(C::in) is semidet :- not list.member(C, Named) ),
        all_capabilities, Missing),
    list.filter(
        ( pred(L::in) is semidet :- not yaml_bool(L ^ ye_value, _) ),
        Lines, NotBool),
    list.filter_map(
        ( pred(L::in, C::out) is semidet :-
            yaml_bool(L ^ ye_value, yes),
            capability_named(L ^ ye_key, C)
        ), Lines, SetCaps),
    Settings = set.list_to_set(SetCaps),
    ( if Unknown = [First | _] then
        Result = registration_refused(dv_dialect_unknown_capability,
            "line " ++ string.from_int(First ^ ye_line) ++ ": `settings` "
                ++ "names " ++ quoted(list.map(entry_key, Unknown))
                ++ ", which is not a capability of [LCAP.1] ([NDLC.2.2])")
    else if NotBool = [Bad | _] then
        Result = registration_refused(dv_dialect_incomplete,
            "line " ++ string.from_int(Bad ^ ye_line) ++ ": `" ++ Bad ^ ye_key
                ++ "` must be set `true` or `false` ([NDLC.2.2])")
    else if Missing = [_ | _] then
        Result = registration_refused(dv_dialect_incomplete,
            "`settings` leaves " ++ quoted(list.map(capability_name, Missing))
                ++ " unset; every capability must be set, and nothing is "
                ++ "derived ([NDLC.2.2])")
    else if lcap_3_8_violations(Settings) = [{Cap, Needed} | _] then
        Result = registration_refused(dv_dialect_dependency,
            constraint_message(Cap, Needed))
    else if ndlc_2_2_deferred(Settings, Message) then
        Result = registration_refused(dv_realtime_deferred, Message)
    else if ndlc_6_1_capability_deferred(Settings, StorageMessage) then
        Result = registration_refused(dv_capability_deferred, StorageMessage)
    else if not ndlc_6_1_nameable(Name) then
        Result = registration_refused(dv_dialect_bad_name,
            bad_name_message(Name))
    else if map.contains(Registry, Name) then
        Result = registration_refused(dv_dialect_duplicate_name,
            "dialect `" ++ Name ++ "` is already registered")
    else
        map.det_insert(Name, dialect(Name, Settings), Registry, Registered),
        Result = registered(Registered)
    ).

    %@helper
:- func bad_name_message(string) = string.

bad_name_message(Name) =
    ( if Name = "" then
        "`name` is missing or empty; a dialect needs a name a `use` line "
            ++ "can give ([NDLC.6.1])"
    else
        "dialect name `" ++ Name ++ "` is not one identifier, so no `use` "
            ++ "line could name it ([NDLC.6.1], [LGRA.3.1])"
    ).

    %@spec [NDLC.2.2]
:- pred ndlc_2_2_deferred(settings::in, string::out) is semidet.

ndlc_2_2_deferred(Settings, Message) :-
    Deferred = lcap_2_1_5_deferred_on(Settings),
    Deferred = [_ | _],
    Names = list.map(capability_name, Deferred),
    Message = "`settings` turns on " ++ quoted(Names) ++ ", which is not "
        ++ "part of this edition of DS ([LCAP.2.1.5])".

    %@spec [NDLC.6.1]
    %@spec [LCAP.2.10]
:- pred ndlc_6_1_capability_deferred(settings::in, string::out) is semidet.

ndlc_6_1_capability_deferred(Settings, Message) :-
    Deferred = lcap_2_10_deferred_on(Settings),
    Deferred = [_ | _],
    Names = list.map(capability_name, Deferred),
    Message = "`settings` turns on " ++ quoted(Names) ++ ", which the "
        ++ "storage layer gates, and it is not part of this edition of DS "
        ++ "([LCAP.2.10])".

    %@helper
:- pred yaml_bool(yaml_value::in, bool::out) is semidet.

yaml_bool(yv_other("true"), yes).
yaml_bool(yv_other("false"), no).

    %@helper
:- func entry_key(yaml_entry) = string.

entry_key(E) = E ^ ye_key.

    %@helper
:- func quoted(list(string)) = string.

quoted(Names) = string.join_list(", ",
    list.map((func(N) = "`" ++ N ++ "`"), Names)).

    %@helper
:- func constraint_message(capability, capability) = string.

constraint_message(Cap, Needed) =
    "`" ++ capability_name(Cap) ++ ": true` requires `"
        ++ capability_name(Needed) ++ ": true`, and `" ++ capability_name(Needed)
        ++ "` is false ([LCAP.3.8])".

%-----------------------------------------------------------------------------%
% The program's `use` line -- [LDIA.3]
%-----------------------------------------------------------------------------%

ldia_3_1_resolve(Registry, Use, Result) :-
    Name = Use ^ au_base ^ id_name,
    ( if map.search(Registry, Name, Dialect) then
        ( if ldia_3_2_3_deferred_dialect(Name) then
            Result = resolution_refused([ldia_3_2_3_deferred(Use)])
        else
            ldia_3_1_resolve_known(Use, Name, Dialect, Result)
        )
    else
        Result = resolution_refused([ldia_3_2_2_unknown(Registry, Use)])
    ).

    % Checked before any line is read: `use realtime:` with both capabilities
    % set `false` is still refused.
    %
    %@spec [LDIA.3.2.3]
:- pred ldia_3_2_3_deferred_dialect(string::in) is semidet.

ldia_3_2_3_deferred_dialect("realtime").

    %@spec [LDIA.3.2.3]
:- func ldia_3_2_3_deferred(ast_use) = diagnostic.

ldia_3_2_3_deferred(Use) =
    with_hint(error_at(dv_realtime_deferred, Use ^ au_base ^ id_pos,
        "the `" ++ Use ^ au_base ^ id_name ++ "` dialect is not part of this "
            ++ "edition of DS ([LDIA.3.2.3], [LCAP.2.1.5])"),
        "of the bounded options, only `linear_scan: false` ships").

    % The block's lines, then the deferred settings, then the constraints.
    %
    %@helper
:- pred ldia_3_1_resolve_known(ast_use::in, string::in, dialect::in,
                               resolution::out) is det.

ldia_3_1_resolve_known(Use, Name, Dialect, Result) :-
    ldia_3_3_overrides(Use ^ au_settings, OverrideErrors, Settings, Lines,
        Dialect ^ dl_settings),
    (
        OverrideErrors = [_ | _],
        Result = resolution_refused(OverrideErrors)
    ;
        OverrideErrors = [],
        Program = program_settings(Name, Settings, Lines),
        Deferred = list.map(lcap_2_1_5_deferred(Use, Lines),
                lcap_2_1_5_deferred_on(Settings))
            ++ list.map(lcap_2_10_deferred_line(Use, Lines),
                lcap_2_10_deferred_on(Settings)),
        Violations = lcap_3_8_violations(Settings),
        ( if Deferred = [_ | _] then
            Result = resolution_refused(Deferred)
        else if Violations = [_ | _] then
            Result = resolution_refused(list.map(
                ldia_3_5_1_constraint(Program, Use), Violations))
        else
            Result = resolved(Program)
        )
    ).

    % No dialect that reaches here sets these, so a line did, and `Lines` has
    % its position; the fallback is unreachable.
    %
    %@spec [LDIA.3.3.7]
    %@spec [LCAP.2.1.5]
:- func lcap_2_1_5_deferred(ast_use, map(capability, int), capability)
    = diagnostic.

lcap_2_1_5_deferred(Use, Lines, Cap) =
    with_hint(error_at(dv_realtime_deferred, Pos,
        "`" ++ capability_name(Cap) ++ "` is not part of this edition of DS "
            ++ "([LCAP.2.1.5])"),
        "of the bounded options, only `linear_scan: false` ships") :-
    ( if map.search(Lines, Cap, Line) then
        Pos = pos(Line, 1)
    else
        Pos = Use ^ au_base ^ id_pos
    ).

    %@spec [LDIA.3.3.7]
    %@spec [LCAP.2.10]
:- func lcap_2_10_deferred_line(ast_use, map(capability, int), capability)
    = diagnostic.

lcap_2_10_deferred_line(Use, Lines, Cap) =
    with_hint(error_at(dv_capability_deferred, Pos,
        "`" ++ capability_name(Cap) ++ "` gates the storage layer, which is "
            ++ "not part of this edition of DS ([LCAP.2.10])"),
        "set it `false`, or drop the line: every dialect already does") :-
    ( if map.search(Lines, Cap, Line) then
        Pos = pos(Line, 1)
    else
        Pos = Use ^ au_base ^ id_pos
    ).

    %@spec [LDIA.3.2.2]
:- func ldia_3_2_2_unknown(registry, ast_use) = diagnostic.

ldia_3_2_2_unknown(Registry, Use) =
    with_hint(error_at(dv_unknown_dialect, Use ^ au_base ^ id_pos,
        "unknown dialect `" ++ Use ^ au_base ^ id_name ++ "` ([LDIA.3.2.2])"),
        "registered dialects: " ++ string.join_list(", ", map.keys(Registry))).

    %@spec [LDIA.3.3.1]
    %@spec [LDIA.3.3.2]
    %@spec [LDIA.3.3.6]
:- pred ldia_3_3_overrides(list(ast_setting)::in, list(diagnostic)::out,
                           settings::out, map(capability, int)::out,
                           settings::in) is det.

ldia_3_3_overrides(Lines, Errors, Settings, LineOf, Base) :-
    list.foldl4(override_line, Lines, [], RevErrors, Base, Settings,
        map.init, LineOf, map.init, _),
    Errors = list.reverse(RevErrors).

    %@helper
:- pred override_line(ast_setting::in,
                      list(diagnostic)::in, list(diagnostic)::out,
                      settings::in, settings::out,
                      map(capability, int)::in, map(capability, int)::out,
                      map(string, int)::in, map(string, int)::out) is det.

override_line(ast_setting(Id, Value), !Errors, !Settings, !LineOf, !Seen) :-
    Name = Id ^ id_name,
    Pos = Id ^ id_pos,
    ( if map.search(!.Seen, Name, FirstLine) then
        !:Errors = [error_at(dv_capability_duplicate, Pos,
            "`" ++ Name ++ "` is set twice in the `use` block; the first is "
                ++ "on line " ++ string.from_int(FirstLine)
                ++ " ([LDIA.3.3.6])") | !.Errors]
    else if capability_named(Name, Cap) then
        map.det_insert(Name, Pos ^ p_line, !Seen),
        map.set(Cap, Pos ^ p_line, !LineOf),
        (
            Value = yes,
            set.insert(Cap, !Settings)
        ;
            Value = no,
            set.delete(Cap, !Settings)
        )
    else
        map.det_insert(Name, Pos ^ p_line, !Seen),
        !:Errors = [with_hint(error_at(dv_unknown_capability, Pos,
            "`" ++ Name ++ "` is not a capability of the registry "
                ++ "([LCAP.1], [LDIA.3.3.2])"),
            "capabilities: " ++ string.join_list(", ",
                list.map(capability_name, all_capabilities))) | !.Errors]
    ).

    %@spec [LDIA.3.5.1]
:- func ldia_3_5_1_constraint(program_settings, ast_use,
                              {capability, capability}) = diagnostic.

ldia_3_5_1_constraint(Program, Use, {Cap, Needed}) =
    with_hint(error_at(dv_capability_constraint, Use ^ au_pos,
        constraint_message(Cap, Needed) ++ "; " ++ capability_name(Cap)
            ++ " is " ++ source_of(Program, Cap) ++ " and "
            ++ capability_name(Needed) ++ " is " ++ source_of(Program, Needed)),
        "set `" ++ capability_name(Needed) ++ ": true` or `"
            ++ capability_name(Cap) ++ ": false` in the `use` block").

    %@spec [LDIA.5.3]
:- func source_of(program_settings, capability) = string.

source_of(Program, Cap) = Source :-
    Value = ( if enabled(Program, Cap) then "true" else "false" ),
    ( if map.search(Program ^ ps_lines, Cap, Line) then
        Source = Value ++ " (line " ++ string.from_int(Line)
            ++ " of the `use` block)"
    else
        Source = Value ++ " (dialect `" ++ Program ^ ps_dialect ++ "`)"
    ).

%-----------------------------------------------------------------------------%
% Per-construct validation -- [LDIA.3.4], [LDIA.5]
%-----------------------------------------------------------------------------%

ldia_3_4_1_gate(RF) = list.filter_map(
    ( func(Site) = D is semidet :-
        not enabled(RF ^ rf_program, Site ^ us_cap),
        D = ldia_5_1_disabled(RF ^ rf_program, Site)
    ), use_sites(RF)).

    % `dsc.driver` adds the library, for a construct inside one ([LDIA.5.8]).
    %
    %@spec [LDIA.5.1]
    %@spec [LDIA.5.2]
    %@spec [LDIA.5.4]
    %@spec [LDIA.5.5]
:- func ldia_5_1_disabled(program_settings, use_site) = diagnostic.

ldia_5_1_disabled(Program, use_site(Cap, Construct, Pos)) =
    with_hint(error_at(dv_capability_disabled, Pos,
        Construct ++ " is not permitted: capability `" ++ capability_name(Cap)
            ++ "` is " ++ source_of(Program, Cap)),
        lfca_1_3_hint(Cap)).

ldia_5_1_disabled_at(Program, Cap, Construct, Pos) =
    ldia_5_1_disabled(Program, use_site(Cap, Construct, Pos)).

    %@spec [LFCA.1.3]
:- func lfca_1_3_hint(capability) = string.

lfca_1_3_hint(cap_realtime) = "drop the construct, or set `realtime: true`".
lfca_1_3_hint(cap_constspace) = "drop the construct, or set `constspace: true`".
lfca_1_3_hint(cap_linear_scan) =
    "anchor the join on a full `logical` key, or set `linear_scan: true`".
lfca_1_3_hint(cap_logical) =
    "use `scope explicit`, `scope ttl` or `scope activation` instead "
        ++ "([LNOG.3.1])".
lfca_1_3_hint(cap_dynamic_ttl) =
    "set `dynamic_ttl: true`, or remove the `retain:` override".
lfca_1_3_hint(cap_regex) =
    "compare against fixed strings, or set `regex: true` ([LFCA.13.1])".
lfca_1_3_hint(cap_float) =
    "use `Int` arithmetic and `//` for division, or set `float: true` "
        ++ "([LCAP.2.9])".
lfca_1_3_hint(cap_call) =
    "move the rule to a tier where `call` is enabled".
lfca_1_3_hint(cap_publish) =
    "move the rule to a non-topmost tier, or use the cache plane as shared "
        ++ "mutable state instead of cross-tier facts".
lfca_1_3_hint(cap_cache) =
    "keep the state in a `logical` fact instead; `cached(...)` reads are "
        ++ "unaffected".
lfca_1_3_hint(cap_cache_delete) =
    "use `cache` with a short TTL; explicit invalidation is lost".
lfca_1_3_hint(cap_nocooldown) =
    "give the call an explicit numeric cooldown".
lfca_1_3_hint(cap_series) =
    "the tier has no series subsystem; restructure to not need windowed "
        ++ "aggregation".
lfca_1_3_hint(cap_sampled_slots) =
    "drop the `sampled` marker".
lfca_1_3_hint(cap_persist_on_series) =
    "drop `persist:`; series values are then in-memory only".
lfca_1_3_hint(cap_storage_hydrate_facts) =
    "keep the facts live with long TTLs instead; the facts plane has no "
        ++ "other read".
lfca_1_3_hint(cap_storage_hydrate_samples) =
    "maintain the aggregate in an in-memory `series`, where the program's "
        ++ "`series` capability is `true` ([LFCA.5.1])".

rdsc_16_2_8_requires(Program, Modules) = Requires :-
    Used = set.list_to_set(list.map((func(S) = S ^ us_cap),
        list.condense(list.map(use_sites, Modules)))),
    Strategy = set.list_to_set(list.filter(
        ( pred(C::in) is semidet :- enabled(Program, C) ),
        [cap_realtime, cap_constspace])),
    ( if
        enabled(Program, cap_dynamic_ttl),
        list.member(M, Modules),
        has_retain(M ^ rf_ast ^ af_decls)
    then
        TtlSet = set.make_singleton_set(cap_dynamic_ttl)
    else
        TtlSet = set.init
    ),
    % An injected schema's `Float` slot is no use site, and the artefact carries
    % it. Under `float: false` `requires` then leaves `enabled` ([RDSC.16.2.3])
    % and the loader refuses the artefact.
    ( if
        list.member(InjMod, Modules),
        list.member(InjDecl, InjMod ^ rf_ast ^ af_decls),
        InjDecl = ad_schema(InjSchema),
        InjSchema ^ as_origin = compiler_injected,
        list.member(InjField, InjSchema ^ as_fields),
        float_slot(InjMod, InjField)
    then
        InjectedSet = set.make_singleton_set(cap_float)
    else
        InjectedSet = set.init
    ),
    Requires = set.union_list([Used, Strategy, TtlSet, InjectedSet]).

%-----------------------------------------------------------------------------%
% Where a module uses a construct capability -- [LCAP.1], [LFCA]
%-----------------------------------------------------------------------------%
%
% One site per place an author would edit. `float` is found by the shapes that
% introduce one, not by typing every expression. A builtin returning `Float` from
% non-`Float` arguments is not found.

    %@helper
:- type use_site
    --->    use_site(
                us_cap       :: capability,
                us_construct :: string,
                us_pos       :: pos
            ).

    %@helper
:- func use_sites(resolved_file) = list(use_site).

use_sites(RF) = list.condense(list.map(decl_sites(RF), RF ^ rf_ast ^ af_decls)).

    %@helper
:- func decl_sites(resolved_file, ast_decl) = list(use_site).

decl_sites(RF, Decl) = Sites :-
    (
        Decl = ad_schema(S),
        ( if S ^ as_origin = author_declared then
            Sites = schema_sites(RF, S)
        else
            Sites = []
        )
    ;
        Decl = ad_rule(R),
        Sites = rule_sites(RF, R)
    ;
        Decl = ad_const(C),
        C = ast_const(_, Form, Pos, _, _),
        (
            Form = acf_value(MaybeAnn, E),
            Sites = annotation_sites(MaybeAnn, Pos) ++ expr_sites(RF, E)
        ;
            Form = acf_colon_literal(E),
            Sites = expr_sites(RF, E)
        )
    ;
        Decl = ad_series(Ser),
        Sites = series_sites(Ser)
    ;
        ( Decl = ad_service(_)
        ; Decl = ad_unit(_)
        ; Decl = ad_opaque(_)
        ; Decl = ad_test(_)
        ; Decl = ad_import(_)
        ),
        Sites = []
    ;
        % No dialect gates it ([LGRA.24.2]).
        Decl = ad_initial(_),
        Sites = []
    ).

    %@helper
:- func schema_sites(resolved_file, ast_schema) = list(use_site).

schema_sites(RF, S) = LifecycleSites ++ FieldSites :-
    Name = S ^ as_name ^ id_name,
    ( if S ^ as_lifecycle = al_logical(_) then
        LifecycleSites = [use_site(cap_logical,
            "schema `" ++ Name ++ "` declared `scope logical`", S ^ as_pos)]
    else
        LifecycleSites = []
    ),
    FieldSites = list.condense(list.map(field_sites(RF, Name),
        S ^ as_fields)).

    %@helper
:- func field_sites(resolved_file, string, ast_field) = list(use_site).

field_sites(RF, Schema, F) = TypeSites ++ MarkerSites :-
    Slot = "`" ++ Schema ++ "." ++ F ^ af_name ^ id_name ++ "`",
    ( if float_slot(RF, F) then
        TypeSites = [use_site(cap_float, "the `Float` slot " ++ Slot,
            F ^ af_pos)]
    else
        TypeSites = []
    ),
    MarkerSites = list.filter_map(
        ( func(M) = use_site(cap_sampled_slots,
                "the `sampled` marker on " ++ Slot, P) is semidet :-
            M = am_sampled(P)
        ), F ^ af_markers).

    % `Float`, or a unit whose dimension stores `float64`.
    %
    %@helper
:- pred float_slot(resolved_file::in, ast_field::in) is semidet.

float_slot(RF, Field) :-
    slot_entry(RF, Field, Entry),
    luni_7_1_slot_type(RF ^ rf_unit_storage, Entry, non_null)
        = ds_type(lk_float, _, _).

    %@helper
:- func annotation_sites(maybe(ast_annotation), pos) = list(use_site).

annotation_sites(no, _) = [].
annotation_sites(yes(Ann), Pos) =
    ( if Ann ^ aan_type ^ id_name = "Float" then
        [use_site(cap_float, "a `Float` annotation", Pos)]
    else
        []
    ).

    %@helper
:- func series_sites(ast_series) = list(use_site).

series_sites(Ser) = [use_site(cap_series, "a `series` declaration", Pos)]
        ++ PersistSites ++ FloatSites :-
    Pos = Ser ^ asr_pos,
    PersistSites = list.filter_map(
        ( func(Opt) = use_site(cap_persist_on_series,
                "`persist:` on a `series` declaration", P) is semidet :-
            Opt = abk_persist(_, P)
        ), Ser ^ asr_opts),
    FloatSites = list.filter_map(
        ( func(Agg) = use_site(cap_float, "the `" ++ Agg ^ id_name
                ++ "` aggregation, which produces a `Float`", Agg ^ id_pos)
            is semidet :-
            float_aggregation(Agg ^ id_name)
        ), list.condense(list.map((func(L) = L ^ asl_aggs),
            Ser ^ asr_lines))).

    %@helper
:- pred float_aggregation(string::in) is semidet.

float_aggregation(Name) :-
    ( list.member(Name, ["mean", "avg", "stdev", "variance", "rate",
        "integral", "active_fraction", "onset_rate", "median", "ewma"])
    ; string.remove_prefix("p", Name, Digits),
      Digits \= "",
      string.all_match(char.is_digit, Digits)
    ).

%-----------------------------------------------------------------------------%
% Rules
%-----------------------------------------------------------------------------%

    %@helper
:- func rule_sites(resolved_file, ast_rule) = list(use_site).

rule_sites(RF, R) = LhsSites ++ LetSites ++ ActionSites ++ AfterSites :-
    LhsSites = list.condense(list.map(lhs_sites(RF), R ^ ar_lhs)),
    Rhs = R ^ ar_rhs,
    LetSites = list.condense(list.map(let_sites(RF), Rhs ^ arr_lets)),
    ActionSites = list.condense(list.map(action_sites(RF),
        Rhs ^ arr_actions)),
    AfterSites = list.condense(list.map(after_sites(RF), Rhs ^ arr_afters)).

    %@helper
:- func lhs_sites(resolved_file, ast_lhs_clause) = list(use_site).

lhs_sites(RF, alc_pattern(P)) = pattern_sites(RF, P).
lhs_sites(RF, alc_then(Step)) = body_sites(RF, Step ^ ats_body).

    %@helper
:- func pattern_sites(resolved_file, ast_pattern) = list(use_site).

pattern_sites(RF, ap_simple(B)) = body_sites(RF, B).
pattern_sites(RF, ap_negated(B, _)) = body_sites(RF, B).
pattern_sites(RF, ap_sequence(_, Head, Steps, _)) =
    body_sites(RF, Head)
        ++ list.condense(list.map(
            ( func(S) = body_sites(RF, S ^ ats_body) ), Steps)).

    %@helper
:- func body_sites(resolved_file, ast_pattern_body) = list(use_site).

body_sites(RF, B) = maybe_expr_sites(RF, B ^ apb_where)
    ++ ( if B ^ apb_capture = yes(C) then expr_sites(RF, C ^ acap_match)
         else [] ).

    %@helper
:- func let_sites(resolved_file, ast_let_decl) = list(use_site).

let_sites(RF, Decl) = list.condense(list.map(binding_sites(RF),
    Decl ^ ald_bindings)).

    %@helper
:- func binding_sites(resolved_file, ast_let_binding) = list(use_site).

binding_sites(RF, alb_simple(_, Ann, E, Pos)) =
    annotation_sites(Ann, Pos) ++ expr_sites(RF, E).
binding_sites(RF, alb_capture(_, E, _)) = expr_sites(RF, E).

    %@helper
:- func action_sites(resolved_file, ast_action) = list(use_site).

action_sites(RF, Action) = HeadSites ++ FlagSites ++ ArgSites ++ AsSites
        ++ ContinuationSites :-
    Pos = Action ^ aac_pos,
    Head = Action ^ aac_head,
    Args = Action ^ aac_args ++ block_args(Action ^ aac_block),
    HeadSites = head_sites(Head, Pos),
    FlagSites = list.filter_map(
        ( func(Arg) = Site is semidet :-
            Arg = aaa_flag(Id),
            ( if Id ^ id_name = "nocooldown" then
                Site = use_site(cap_nocooldown, "the `nocooldown` flag",
                    Id ^ id_pos)
            else
                Id ^ id_name = "logical",
                Site = use_site(cap_logical, "`logical` on `"
                    ++ head_word(Head) ++ "`", Id ^ id_pos)
            )
        ), Args),
    ArgSites = list.condense(list.map(
        ( func(Arg) = ( if Arg = aaa_kwarg(_, E, _) then expr_sites(RF, E)
                        else [] ) ), Args)),
    AsSites = maybe_expr_sites(RF, Action ^ aac_as),
    ContinuationSites = list.condense(list.map(continuation_sites(RF),
        continuations(Action ^ aac_block))).

    %@helper
:- func head_sites(ast_action_head, pos) = list(use_site).

head_sites(aah_log(_, _), _) = [].
head_sites(aah_emit(_), _) = [].
head_sites(aah_withdraw(_), _) = [].
head_sites(aah_call(Ref), Pos) = [use_site(cap_call, "`call`", Pos)
    | ( if storage_capability(Ref, Cap, Name) then
            [use_site(Cap, "`call " ++ Name ++ "`", Pos)]
        else [] )].
head_sites(aah_publish(_), Pos) = [use_site(cap_publish, "`publish`", Pos)].
head_sites(aah_cache, Pos) = [use_site(cap_cache, "`cache`", Pos)].
head_sites(aah_cache_delete, Pos) =
    [use_site(cap_cache_delete, "`cache_delete`", Pos)].
    % `lgra_10_1_5_record_event` refuses this head under every dialect.
head_sites(aah_record_event(_), _) = [].

    % `call <method>` by its bare name; the capability is `storage_<method>`.
    %
    %@helper
:- pred storage_capability(ast_service_ref::in, capability::out,
                           string::out) is semidet.

storage_capability(asr_bare([Method]), Cap, Name) :-
    Name = Method ^ id_name,
    capability_named("storage_" ++ Name, Cap).

    %@helper
:- func head_word(ast_action_head) = string.

head_word(aah_log(_, _)) = "log".
head_word(aah_call(_)) = "call".
head_word(aah_emit(_)) = "emit".
head_word(aah_publish(_)) = "publish".
head_word(aah_cache) = "cache".
head_word(aah_cache_delete) = "cache_delete".
head_word(aah_record_event(_)) = "record_event".
head_word(aah_withdraw(_)) = "withdraw".

    %@helper
:- func block_args(ast_action_block) = list(ast_action_arg).

block_args(aab_none) = [].
block_args(aab_kwargs(Args)) = Args.
block_args(aab_call(Args, _)) = Args.

    %@helper
:- func continuations(ast_action_block) = list(ast_continuation).

continuations(aab_none) = [].
continuations(aab_kwargs(_)) = [].
continuations(aab_call(_, Conts)) = Conts.

    %@helper
:- func continuation_sites(resolved_file, ast_continuation) = list(use_site).

continuation_sites(RF, acont_on(E, Actions, _)) =
    expr_sites(RF, E) ++ list.condense(list.map(action_sites(RF), Actions)).
continuation_sites(RF, acont_timeout(E, Actions, _)) =
    expr_sites(RF, E) ++ list.condense(list.map(action_sites(RF), Actions)).
continuation_sites(RF, acont_error(_, Actions, _)) =
    list.condense(list.map(action_sites(RF), Actions)).

    %@helper
:- func after_sites(resolved_file, ast_after_clause) = list(use_site).

after_sites(RF, A) = expr_sites(RF, A ^ aaf_duration)
    ++ maybe_expr_sites(RF, A ^ aaf_as)
    ++ list.condense(list.map(action_sites(RF), A ^ aaf_actions))
    ++ list.condense(list.map(after_sites(RF), A ^ aaf_nested)).

    % At every depth; a `retain:` this missed would be refused at load
    % ([RDSC.16.2.8]).
    %
    %@helper
:- pred has_retain(list(ast_decl)::in) is semidet.

has_retain(Decls) :-
    list.member(ad_rule(R), Decls),
    Rhs = R ^ ar_rhs,
    Actions = list.condense(list.map(nested_actions,
        Rhs ^ arr_actions ++ list.condense(list.map(after_actions,
            Rhs ^ arr_afters)))),
    list.member(Action, Actions),
    list.member(aaa_kwarg(Name, _, _),
        Action ^ aac_args ++ block_args(Action ^ aac_block)),
    Name ^ id_name = "retain".

    %@helper
:- func after_actions(ast_after_clause) = list(ast_action).

after_actions(A) = A ^ aaf_actions
    ++ list.condense(list.map(after_actions, A ^ aaf_nested)).

    %@helper
:- func nested_actions(ast_action) = list(ast_action).

nested_actions(Action) = [Action | list.condense(list.map(
    ( func(C) = list.condense(list.map(nested_actions,
        continuation_actions(C))) ), continuations(Action ^ aac_block)))].

    %@helper
:- func continuation_actions(ast_continuation) = list(ast_action).

continuation_actions(acont_on(_, Actions, _)) = Actions.
continuation_actions(acont_timeout(_, Actions, _)) = Actions.
continuation_actions(acont_error(_, Actions, _)) = Actions.

%-----------------------------------------------------------------------------%
% Expressions
%-----------------------------------------------------------------------------%

    %@helper
:- func maybe_expr_sites(resolved_file, maybe(lgra_9_3_1_expr))
    = list(use_site).

maybe_expr_sites(_, no) = [].
maybe_expr_sites(RF, yes(E)) = expr_sites(RF, E).

    %@helper
:- func expr_sites(resolved_file, lgra_9_3_1_expr) = list(use_site).

expr_sites(RF, E) = own_sites(E)
    ++ list.condense(list.map(expr_sites(RF), expr_children(E))).

    %@helper
:- func own_sites(lgra_9_3_1_expr) = list(use_site).

own_sites(E) = Sites :-
    ( if E = ex_float(_, Pos) then
        Sites = [use_site(cap_float, "a `Float` literal", Pos)]
    else if
        E = ex_unit(_, Suffix, Pos),
        not luni_10_2_time_unit(llex_12_5_symbol_of(Suffix), _)
    then
        Sites = [use_site(cap_float, "the unit literal `_" ++ Suffix
            ++ "`, whose value is a `Float`", Pos)]
    else if
        E = ex_binary(bo_div, L, R, Pos),
        not ( L = ex_int(_, _), R = ex_int(_, _) )
    then
        % `INT_LIT / INT_LIT` is a `Rational` literal, not the operator
        % ([LEXP.7.4]).
        Sites = [use_site(cap_float, "`/`, which produces a `Float`", Pos)]
    else if E = ex_cast(_, Target, _, Pos), Target ^ id_name = "Float" then
        Sites = [use_site(cap_float, "a cast to `Float`", Pos)]
    else if E = ex_match(_, _, _, _, Pos) then
        Sites = [use_site(cap_regex, "a regular-expression match", Pos)]
    else
        Sites = []
    ).

    %@helper
:- func expr_children(lgra_9_3_1_expr) = list(lgra_9_3_1_expr).

expr_children(ex_int(_, _)) = [].
expr_children(ex_float(_, _)) = [].
expr_children(ex_string(_, _)) = [].
expr_children(ex_unit(_, _, _)) = [].
expr_children(ex_bool(_, _)) = [].
expr_children(ex_null(_)) = [].
expr_children(ex_name(_)) = [].
expr_children(ex_unary(_, E, _)) = [E].
expr_children(ex_not(E, _)) = [E].
expr_children(ex_binary(_, L, R, _)) = [L, R].
expr_children(ex_compare(First, Steps, _)) =
    [First | list.map((func(S) = S ^ cs_right), Steps)].
expr_children(ex_is(E, _, _, _)) = [E].
expr_children(ex_slot(E, _, _)) = [E].
expr_children(ex_index(E, I, _)) = [E, I].
expr_children(ex_call(Callee, Args, _)) = [Callee | Args].
expr_children(ex_cast(E, _, _, _)) = [E].
expr_children(ex_match(E, _, _, _, _)) = [E].

%-----------------------------------------------------------------------------%
:- end_module dsc.dialect.
%-----------------------------------------------------------------------------%

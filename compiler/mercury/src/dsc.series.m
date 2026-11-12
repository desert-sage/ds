% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.series -- the `series` declaration's own checks.
%
% Companion-slot resolution is `dsc.typecheck`'s, through `lser_6_11_1_cursor`.
%-----------------------------------------------------------------------------%

:- module dsc.series.
:- interface.

:- import_module dsc.diag.
:- import_module dsc.validate_codes.
:- import_module dsc.resolve.
:- import_module dsc.token.

:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%

    %@spec [LSER.7.1]
    %@spec [LSER.10.15]
    %@spec [LSER.13.6]
:- pred lser_7_1_declarations(resolved_file::in, list(diagnostic)::out) is det.

    % One observation line, with the declaration's slot already resolved.
    %
    %@helper
:- type series_obs
    --->    series_obs(
                so_slot  :: string,
                so_label :: maybe(string),
                so_aggs  :: list(string),
                so_pos   :: pos
            ).

    %@spec [LSER.6.9.1]
:- func lser_6_9_1_observations(resolved_file, string) = list(series_obs).

    %@helper
:- type cursor_outcome
    --->    cursor_resolved(series_obs, string)
    ;       cursor_failed(diagnostic).

    % The last of the components is the aggregation. The caller has established
    % that they are a cursor read.
    %
    %@spec [LSER.6.11.1]
    %@spec [LSER.6.9.3]
    %@spec [LSER.6.9.4]
    %@spec [LSER.6.9.2]
    %@spec [LSER.6.9.5]
    %@spec [LSER.6.4]
    %@spec [LSER.6.7.1]
    %@spec [LSER.6.8.5]
    %@spec [LSER.6.10.3]
:- func lser_6_11_1_cursor(resolved_file, string, list(ident), pos)
    = cursor_outcome.

    % The aggregations a `series` declaration may name.
    %
    %@spec [LSER.17.2]
    %@spec [LSER.16.4.1]
    %@spec [LSER.17.6]
    %@spec [LSIG.1.1]
:- pred lser_17_2_aggregation(string::in) is semidet.

    % The subset a companion slot may name.
    %
    %@spec [LSER.6.5]
:- pred lser_6_5_companion_aggregation(string::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.
:- import_module ds.capability.
:- import_module dsc.ast.
:- import_module dsc.builtins.
:- import_module dsc.capability.
:- import_module dsc.expr.
:- import_module dsc.types.

:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module pair.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

lser_7_1_declarations(RF, Diagnostics) :-
    Decls = RF ^ rf_ast ^ af_decls,
    list.foldl2(check_series(RF), Decls, map.init, _, [], RevDiagnostics),
    lsig_3_6_gap_hold_no_clock(RF, ClockWarnings),
    Diagnostics = list.reverse(RevDiagnostics) ++ ClockWarnings.

    % Any window in the file counts, though the clause says "the rule": the
    % `$ClockTick` a window head-inserts re-drives the whole agenda. One warning
    % per series, at the first gap-hold `integral` line.
    %
    %@spec [LSIG.3.6]
:- pred lsig_3_6_gap_hold_no_clock(resolved_file::in, list(diagnostic)::out)
    is det.

lsig_3_6_gap_hold_no_clock(RF, Warnings) :-
    Decls = RF ^ rf_ast ^ af_decls,
    ( if
        realtime_file(RF),
        not (
            list.member(Decl, Decls),
            Decl = ad_rule(Rule),
            list.member(Clause, Rule ^ ar_lhs),
            clause_has_window(Clause)
        )
    then
        Warnings = list.filter_map(gap_hold_warning, Decls)
    else
        Warnings = []
    ).

    %@helper
:- pred clause_has_window(ast_lhs_clause::in) is semidet.

clause_has_window(alc_pattern(ap_simple(Body))) :-
    Body ^ apb_within = yes(_).
clause_has_window(alc_pattern(ap_negated(Body, _))) :-
    Body ^ apb_within = yes(_).

    %@helper
:- func gap_hold_warning(ast_decl) = diagnostic is semidet.

gap_hold_warning(Decl) = D :-
    Decl = ad_series(Series),
    list.find_first_match(gap_hold_integral, Series ^ asr_lines, Line),
    Slot = Series ^ asr_slot ^ asf_slot ^ id_name,
    D = with_hint(warning_at(dv_series_gap_hold_no_clock, Line ^ asl_pos,
        "`integral ... gap hold` on `" ++ Slot ++ "` advances with the wall "
            ++ "clock at query time, and no rule in this file has a `within` "
            ++ "window to re-drive it ([LSIG.3.6])"),
        "give a rule a `within` window, or use `gap zero` "
            ++ "or `gap skip`, which advance only on assertion").

    %@helper
:- pred gap_hold_integral(ast_series_line::in) is semidet.

gap_hold_integral(Line) :-
    list.member(Agg, Line ^ asl_aggs),
    Agg ^ id_name = "integral",
    ( Line ^ asl_gap = no
    ; Line ^ asl_gap = yes(gp_hold(_))
    ).

    %@helper
:- pred check_series(resolved_file::in, ast_decl::in,
                     map(string, pos)::in, map(string, pos)::out,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

check_series(RF, Decl, !Seen, !Errors) :-
    ( if Decl = ad_series(Series) then
        Ref = Series ^ asr_slot,
        Pos = Series ^ asr_pos,
        lser_7_7_2_target(RF, Ref, Pos, Target, !Errors),
        (
            Target = yes(Schema - Slot),
            Key = Schema ++ "." ++ Slot,
            ( if map.search(!.Seen, Key, Prior) then
                D = with_hint(error_with(dv_series_duplicate_decl, Pos,
                    "`series " ++ Key ++ "`: one declaration per "
                        ++ "(schema, slot) ([LSER.10.15])",
                    Prior, "first declaration here"),
                    "merge the observation lines into the first declaration"),
                !:Errors = [D | !.Errors]
            else
                map.det_insert(Key, Pos, !Seen)
            ),
            lser_6_12_1_label_names(RF, Schema, Series, !Errors),
            lser_17_7_applicability(RF, Schema, Slot, Series, !Errors),
            lnul_8_6_nulls(RF, Schema, Slot, Series, !Errors),
            lser_7_6_1_identity(RF, Schema, Series, !Errors)
        ;
            Target = no
        ),
        lser_6_8_3_labels(Series, !Errors),
        lser_6_8_6_label_aggs(Series, !Errors),
        lser_13_11_duplicate_options(Series ^ asr_opts, !Errors),
        lser_13_14_capacity(Series, !Errors),
        list.foldl(lser_15_1_accuracy, Series ^ asr_lines, !Errors)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% What a declaration groups by -- [LSER.7.6.1]
%-----------------------------------------------------------------------------%

    % With `by:` omitted, only a `logical` schema with one `key` slot groups.
    % `explicit` and `activation` are not refused: the clause says nothing of them.
    %
    %@spec [LSER.7.6.1]
    %@spec [LSER.7.6.2]
    %@spec [LSER.10.13]
:- pred lser_7_6_1_identity(resolved_file::in, string::in, ast_series::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

lser_7_6_1_identity(RF, SchemaName, Series, !Errors) :-
    ( if
        map.search(RF ^ rf_types, SchemaName, Entry),
        Entry = te_schema(Schema)
    then
        Pos = Series ^ asr_pos,
        Label = "`series " ++ SchemaName ++ "."
            ++ Series ^ asr_slot ^ asf_slot ^ id_name ++ "`",
        ( if first_by(Series ^ asr_opts) = yes(By) then
            (
                By = aby_name(Id),
                ( if has_slot(Schema, Id ^ id_name) then
                    true
                else
                    !:Errors = [with_hint(error_at(dv_series_bad_identity_slot,
                        Id ^ id_pos,
                        Label ++ ": `by: " ++ Id ^ id_name ++ "` names no slot "
                            ++ "of `" ++ SchemaName ++ "` ([LSER.7.6.1])"),
                        "name a slot the schema declares, or write `by: none` "
                            ++ "for one global series") | !.Errors]
                )
            ;
                By = aby_none(_)
            )
        else
            Lifecycle = Schema ^ as_lifecycle,
            (
                Lifecycle = al_ttl(_, _),
                !:Errors = [with_hint(error_at(dv_series_no_identity_slot,
                    Pos,
                    Label ++ ": `" ++ SchemaName ++ "` is a `ttl` schema, "
                        ++ "which carries no identity for a series to follow, "
                        ++ "and `entity_id` has no series-grouping privilege "
                        ++ "([LSER.7.6.1])"),
                    "write `by: <slot>` naming the slot to group by, or "
                        ++ "`by: none` for one global series")
                    | !.Errors]
            ;
                Lifecycle = al_logical(_),
                Keys = list.filter(is_key_field, Schema ^ as_fields),
                ( if Keys = [_] then
                    true
                else if Keys = [_, _ | _] then
                    KeyNames = list.map((func(F) = "`" ++ F ^ af_name ^ id_name
                        ++ "`"), Keys),
                    !:Errors = [with_hint(error_at(dv_series_no_identity_slot,
                        Pos,
                        Label ++ ": `" ++ SchemaName ++ "`'s key is several "
                            ++ "slots (" ++ string.join_list(", ", KeyNames)
                            ++ "), and a series groups by one ([LSER.7.6.1])"),
                        "write `by: <slot>` naming the one slot to group by, "
                            ++ "or `by: none` for one global series")
                        | !.Errors]
                else
                    !:Errors = [with_hint(error_at(dv_series_no_identity_slot,
                        Pos,
                        Label ++ ": `" ++ SchemaName ++ "` declares no `key`, "
                            ++ "so there is no identity to group by, and "
                            ++ "`entity_id` has no series-grouping privilege "
                            ++ "([LSER.7.6.1])"),
                        "mark the identity slot `key`, write `by: <slot>`, or "
                            ++ "write `by: none` for one global series")
                        | !.Errors]
                )
            ;
                ( Lifecycle = al_explicit
                ; Lifecycle = al_internal
                ; Lifecycle = al_activation
                )
            )
        )
    else
        true
    ).

    %@helper
:- func first_by(list(ast_block_kwarg)) = maybe(ast_by_value).

first_by([]) = no.
first_by([Opt | Opts]) =
    ( if Opt = abk_by(By, _) then yes(By) else first_by(Opts) ).

    %@helper
:- pred is_key_field(ast_field::in) is semidet.

is_key_field(Field) :-
    list.any_true(is_key_marker, Field ^ af_markers).

    %@helper
:- pred is_key_marker(ast_marker::in) is semidet.

is_key_marker(am_key(_)).

%-----------------------------------------------------------------------------%
% Which slot a declaration observes -- [LSER.7.7]
%-----------------------------------------------------------------------------%

    % `no` means a diagnostic was recorded.
    %
    %@spec [LSER.7.7.2]
    %@spec [LSER.10.17]
    %@spec [LSER.13.7]
    %@spec [LSER.13.8]
:- pred lser_7_7_2_target(resolved_file::in, ast_slot_ref::in, pos::in,
                        maybe(pair(string, string))::out,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

lser_7_7_2_target(RF, Ref, Pos, Target, !Errors) :-
    Slot = Ref ^ asf_slot ^ id_name,
    (
        Ref ^ asf_schema = yes(SchemaId),
        Name = SchemaId ^ id_name,
        ( if
            map.search(RF ^ rf_types, Name, Entry),
            Entry = te_schema(Declared)
        then
            ( if has_slot(Declared, Slot) then
                Target = yes(Declared ^ as_own - Slot)
            else
                Target = no,
                !:Errors = [with_hint(error_at(dv_series_unknown_slot,
                    Ref ^ asf_slot ^ id_pos,
                    "`series " ++ Name ++ "." ++ Slot ++ "`: schema `" ++ Name
                        ++ "` has no slot `" ++ Slot ++ "`"),
                    "a series observes a slot the schema declares")
                    | !.Errors]
            )
        else
            Target = no,
            !:Errors = [error_at(dv_series_unknown_schema, Pos,
                "`series " ++ Name ++ "." ++ Slot ++ "`: unknown schema `"
                    ++ Name ++ "`") | !.Errors]
        )
    ;
        Ref ^ asf_schema = no,
        Owners = schemas_with_slot(RF, Slot),
        (
            Owners = [Schema],
            Target = yes(Schema - Slot)
        ;
            Owners = [],
            Target = no,
            !:Errors = [error_at(dv_series_unknown_slot,
                Ref ^ asf_slot ^ id_pos,
                "`series " ++ Slot ++ "`: no schema in this file declares a "
                    ++ "slot `" ++ Slot ++ "`") | !.Errors]
        ;
            Owners = [First, Second | Rest],
            Target = no,
            !:Errors = [with_hint(error_at(dv_series_ambiguous_slot,
                Ref ^ asf_slot ^ id_pos,
                "`series " ++ Slot ++ "`: " ++ Slot ++ " is declared by "
                    ++ string.join_list(", ", [First, Second | Rest])),
                "qualify it -- `series " ++ First ++ "." ++ Slot ++ ":`")
                | !.Errors]
        )
    ).

    %@helper
:- pred has_slot(ast_schema::in, string::in) is semidet.

has_slot(Schema, Name) :-
    slot_named(Schema ^ as_fields, Name).

    %@helper
:- pred slot_named(list(ast_field)::in, string::in) is semidet.

slot_named([F | Fs], Name) :-
    ( if F ^ af_name ^ id_name = Name then true else slot_named(Fs, Name) ).

    %@helper
:- func schemas_with_slot(resolved_file, string) = list(string).

schemas_with_slot(RF, Slot) =
    list.filter_map(schema_declaring(Slot), RF ^ rf_ast ^ af_decls).

    %@helper
:- func schema_declaring(string, ast_decl) = string is semidet.

schema_declaring(Slot, ad_schema(S)) = S ^ as_own :-
    has_slot(S, Slot).

%-----------------------------------------------------------------------------%
% Labelled lines -- [LSER.6.8.3]
%-----------------------------------------------------------------------------%

    % Counts aggregations among the lines with no `as`.
    %
    %@spec [LSER.6.8.3]
:- pred lser_6_8_3_labels(ast_series::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lser_6_8_3_labels(Series, !Errors) :-
    Unlabelled = list.filter(no_label, Series ^ asr_lines),
    list.foldl2(check_line_aggs, Unlabelled, set.init, _, !Errors).

    %@helper
:- pred no_label(ast_series_line::in) is semidet.

no_label(Line) :-
    Line ^ asl_as = no.

    %@helper
:- pred check_line_aggs(ast_series_line::in, set(string)::in, set(string)::out,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

check_line_aggs(Line, !Seen, !Errors) :-
    list.foldl2(check_agg(Line ^ asl_pos), Line ^ asl_aggs, !Seen, !Errors).

    %@helper
:- pred check_agg(pos::in, ident::in, set(string)::in, set(string)::out,
                  list(diagnostic)::in, list(diagnostic)::out) is det.

check_agg(Pos, Id, !Seen, !Errors) :-
    Name = Id ^ id_name,
    ( if set.contains(!.Seen, Name) then
        D = with_hint(error_at(dv_series_duplicate_agg_needs_label, Pos,
            "`" ++ Name ++ "` is covered by more than one unlabelled line "
                ++ "([LSER.6.8.3]); the companion slot `." ++ Name
                ++ "` would be ambiguous"),
            "add `as <label>` to each line covering `" ++ Name
                ++ "` -- a labelled line is reached as `.<label>." ++ Name
                ++ "` ([LSER.6.8.1])"),
        !:Errors = [D | !.Errors]
    else
        set.insert(Name, !Seen)
    ).

%-----------------------------------------------------------------------------%
% Applicability -- [LSER.17.7]'s two axes
%-----------------------------------------------------------------------------%

    %@spec [LSER.17.7]
:- pred lser_17_7_applicability(resolved_file::in, string::in, string::in,
                                ast_series::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

lser_17_7_applicability(RF, SchemaName, Slot, Series, !Errors) :-
    ( if slot_leaf(RF, SchemaName, Slot, Leaf) then
        Value = yes(Leaf)
    else
        % A slot whose declared type names nothing is `dsc.validate`'s to report.
        Value = no
    ),
    list.foldl(applicability_line(SchemaName, Slot, Value), Series ^ asr_lines,
        !Errors),
    list.foldl(lser_13_5_1_gap(RF, SchemaName, Slot), Series ^ asr_lines,
        !Errors),
    ( if realtime_file(RF) then
        list.foldl(lsig_5_3_realtime(SchemaName, Slot), Series ^ asr_lines,
            !Errors)
    else
        true
    ),
    ( if Value = yes(lk_string), bounded_memory_file(RF) then
        list.foldl(lcsp_4_5_string_series(SchemaName, Slot),
            Series ^ asr_lines, !Errors)
    else
        true
    ).

%-----------------------------------------------------------------------------%
% String-typed series under bounded memory -- [LCSP.4.5]
%-----------------------------------------------------------------------------%

    % The clause's property is "stores values"; `lcsp_4_5_value_storing` lists
    % the combinations that do. One diagnostic per line.
    %
    %@spec [LCSP.4.5]
:- pred lcsp_4_5_string_series(string::in, string::in, ast_series_line::in,
                               list(diagnostic)::in, list(diagnostic)::out)
                               is det.

lcsp_4_5_string_series(SchemaName, Slot, Line, !Errors) :-
    Model = model_name(Line ^ asl_time),
    ( if
        list.find_first_match(
            (pred(Agg::in) is semidet :-
                lcsp_4_5_value_storing(Agg ^ id_name, Model)),
            Line ^ asl_aggs, Found)
    then
        !:Errors = [with_hint(error_at(dv_rt_string_series, Line ^ asl_pos,
            "`series " ++ SchemaName ++ "." ++ Slot ++ "`: `"
                ++ Found ^ id_name ++ " " ++ Model ++ "` stores each `String` "
                ++ "sample, which allocates per sample under bounded memory "
                ++ "([LCSP.4.5])"),
            "series over an interned slot type -- `Int`, `Float` or `Bool` -- "
                ++ "or drop `constspace` / `realtime`") | !.Errors]
    else
        true
    ).

    %@helper
:- pred lcsp_4_5_value_storing(string::in, string::in) is semidet.

lcsp_4_5_value_storing(_, "sample").
lcsp_4_5_value_storing("count_distinct", _).
lcsp_4_5_value_storing("count_of", _).
lcsp_4_5_value_storing("contains", _).
lcsp_4_5_value_storing("first", "sliding").
lcsp_4_5_value_storing("first", "tumbling").
lcsp_4_5_value_storing("last", "sliding").
lcsp_4_5_value_storing("last", "tumbling").
lcsp_4_5_value_storing("count", "sliding").

    %@helper
:- pred bounded_memory_file(resolved_file::in) is semidet.

bounded_memory_file(RF) :-
    % `realtime` requires `constspace` ([LCAP.3.8]).
    enabled(RF ^ rf_program, cap_constspace).

%-----------------------------------------------------------------------------%
% Bounded-memory availability -- [LSIG.5.3]
%-----------------------------------------------------------------------------%

    %@spec [LSIG.5.3]
    %@spec [LSIG.1.5.5]
:- pred lsig_5_3_realtime(string::in, string::in, ast_series_line::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lsig_5_3_realtime(SchemaName, Slot, Line, !Errors) :-
    ( if Line ^ asl_time = atm_all_time(Pos) then
        list.foldl(realtime_unbounded(SchemaName, Slot, Pos), Line ^ asl_aggs,
            !Errors)
    else
        true
    ).

    %@helper
:- pred realtime_unbounded(string::in, string::in, pos::in, ident::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

realtime_unbounded(SchemaName, Slot, Pos, Id, !Errors) :-
    ( if time_integrating(Id ^ id_name) then
        !:Errors = [with_hint(error_at(dv_series_realtime_unbounded_backing,
            Pos,
            "`series " ++ SchemaName ++ "." ++ Slot ++ "`: `" ++ Id ^ id_name
                ++ " all_time` has no bounded backing, and this file is "
                ++ "`realtime` ([LSIG.5.3])"),
            "give it a window -- `" ++ Id ^ id_name
                ++ " sliding <W>` with a W large enough for the totals you "
                ++ "need -- or build host-side for a true cumulative total")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred realtime_file(resolved_file::in) is semidet.

realtime_file(RF) :-
    enabled(RF ^ rf_program, cap_realtime).

%-----------------------------------------------------------------------------%
% The gap-policy phrase -- [LSER.13.5.1]
%-----------------------------------------------------------------------------%

    %@spec [LSER.13.5.1]
    %@spec [LSIG.3.3]
:- pred lser_13_5_1_gap(resolved_file::in, string::in, string::in,
                        ast_series_line::in,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

lser_13_5_1_gap(RF, SchemaName, Slot, Line, !Errors) :-
    ( if Line ^ asl_gap = yes(Policy) then
        Where = "`series " ++ SchemaName ++ "." ++ Slot ++ "`: ",
        list.foldl(gap_needs_integral(Where, Policy), Line ^ asl_aggs, !Errors),
        ( if Policy = gp_skip(SkipPos) then
            lser_13_5_1_skip_scope(RF, SchemaName, Where, SkipPos, !Errors)
        else
            true
        )
    else
        true
    ).

    %@helper
:- pred gap_needs_integral(string::in, lgra_7_6a_gap_policy::in, ident::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

gap_needs_integral(Where, Policy, Id, !Errors) :-
    ( if time_integrating(Id ^ id_name) then
        true
    else
        !:Errors = [with_hint(error_at(dv_series_gap_on_non_integral,
            gap_pos(Policy),
            Where ++ "a `gap` phrase applies only to a time-integrating "
                ++ "aggregation, and `" ++ Id ^ id_name
                ++ "` is not one ([LSER.13.5.1])"),
            "drop the phrase -- only `integral` advances across intervals "
                ++ "with no sample, so only `integral` has a gap to name")
            | !.Errors]
    ).

    %@helper
:- pred time_integrating(string::in) is semidet.

time_integrating("integral").

    %@spec [LSER.13.5.1]
    %@spec [LSIG.3.4]
:- pred lser_13_5_1_skip_scope(resolved_file::in, string::in, string::in,
                               pos::in,
                               list(diagnostic)::in, list(diagnostic)::out)
                               is det.

lser_13_5_1_skip_scope(RF, SchemaName, Where, Pos, !Errors) :-
    ( if
        map.search(RF ^ rf_types, SchemaName, te_schema(Schema)),
        not bounded_lifecycle(Schema ^ as_lifecycle)
    then
        !:Errors = [with_hint(error_at(dv_series_gap_skip_logical, Pos,
            Where ++ "`gap skip` needs a bounded schema -- `scope ttl` or "
                ++ "`scope explicit` -- and `" ++ SchemaName ++ "` is `"
                ++ lifecycle_word(Schema ^ as_lifecycle)
                ++ "` ([LSER.13.5.1])"),
            "a `logical` fact persists until its next meaningful change, so "
                ++ "there is no dead-sensor interval to exclude")
            | !.Errors]
    else
        true
    ).

    %@helper
:- pred bounded_lifecycle(ast_lifecycle::in) is semidet.

bounded_lifecycle(al_ttl(_, _)).
bounded_lifecycle(al_explicit).
    % [LERR.9.5]: at most one live fault fact per site, so the set is bounded.
bounded_lifecycle(al_internal).

    %@helper
:- func lifecycle_word(ast_lifecycle) = string.

lifecycle_word(al_explicit) = "explicit".
lifecycle_word(al_internal) = "internal".
lifecycle_word(al_activation) = "activation".
lifecycle_word(al_logical(_)) = "logical".
lifecycle_word(al_ttl(_, _)) = "ttl".

    %@helper
:- func gap_pos(lgra_7_6a_gap_policy) = pos.

gap_pos(gp_hold(P)) = P.
gap_pos(gp_zero(P)) = P.
gap_pos(gp_skip(P)) = P.

%-----------------------------------------------------------------------------%
% Null absorption -- [LNUL.8.6]
%-----------------------------------------------------------------------------%

    %@spec [LNUL.8.6]
:- pred lnul_8_6_nulls(resolved_file::in, string::in, string::in,
                       ast_series::in,
                       list(diagnostic)::in, list(diagnostic)::out) is det.

lnul_8_6_nulls(RF, SchemaName, Slot, Series, !Errors) :-
    Declared = list.filter_map(
        (func(O) = {W, P} is semidet :- O = abk_nulls(W, P)),
        Series ^ asr_opts),
    ( if
        slot_nullability(RF, SchemaName, Slot, Null),
        slot_leaf(RF, SchemaName, Slot, Leaf)
    then
        ( if
            Declared = [],
            Null = nullable
        then
            !:Errors = [with_hint(error_at(dv_series_nulls_required,
                Series ^ asr_pos,
                "`series " ++ SchemaName ++ "." ++ Slot ++ "`: the source "
                    ++ "slot is nullable, and no `nulls:` policy says what "
                    ++ "a `null` sample does ([LNUL.8.6])"),
                "add `nulls: skip`, `nulls: hold` or `nulls: zero` to the "
                    ++ "block options; there is no default") | !.Errors]
        else if
            Declared = [{_, Pos} | _],
            Null = non_null
        then
            !:Errors = [with_hint(error_at(dv_series_nulls_on_non_nullable,
                Pos,
                "`series " ++ SchemaName ++ "." ++ Slot ++ "`: `nulls:` on "
                    ++ "a source that is not nullable; there is no `null` "
                    ++ "for the policy to absorb ([LNUL.8.6])"),
                "drop `nulls:`, or declare the slot `?`") | !.Errors]
        else if
            Declared = [{Word, Pos} | _],
            Word ^ id_name = "zero",
            not ( Leaf = lk_int ; Leaf = lk_float ; Leaf = lk_duration )
        then
            !:Errors = [with_hint(error_at(dv_series_nulls_zero_non_numeric,
                Pos,
                "`series " ++ SchemaName ++ "." ++ Slot ++ "`: `nulls: zero` "
                    ++ "absorbs 0, which has no meaning for a source that is "
                    ++ "not `Int?` or `Float?` ([LNUL.8.6])"),
                "use `nulls: skip` or `nulls: hold`") | !.Errors]
        else
            true
        )
    else
        true
    ).

    %@helper
:- pred slot_nullability(resolved_file::in, string::in, string::in,
                         nullability::out) is semidet.

slot_nullability(RF, SchemaName, Slot, Null) :-
    map.search(RF ^ rf_types, SchemaName, te_schema(Schema)),
    find_slot(Schema ^ as_fields, Slot, Field),
    Null = Field ^ af_nullable.

    %@helper
:- pred slot_leaf(resolved_file::in, string::in, string::in,
                  leaf_kind::out) is semidet.

slot_leaf(RF, SchemaName, Slot, Leaf) :-
    Types = RF ^ rf_types,
    map.search(Types, SchemaName, te_schema(Schema)),
    find_slot(Schema ^ as_fields, Slot, Field),
    slot_entry(RF, Field, Entry),
    Declared = luni_7_1_slot_type(RF ^ rf_unit_storage, Entry,
        Field ^ af_nullable),
    Leaf = Declared ^ dt_leaf.

    %@helper
:- pred find_slot(list(ast_field)::in, string::in, ast_field::out) is semidet.

find_slot([F | Fs], Name, Found) :-
    ( if F ^ af_name ^ id_name = Name then
        Found = F
    else
        find_slot(Fs, Name, Found)
    ).

    %@helper
:- pred applicability_line(string::in, string::in, maybe(leaf_kind)::in,
                           ast_series_line::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

applicability_line(SchemaName, Slot, Value, Line, !Errors) :-
    list.foldl(applicability_agg(SchemaName, Slot, Value, Line ^ asl_time),
        Line ^ asl_aggs, !Errors).

    %@helper
:- pred applicability_agg(string::in, string::in, maybe(leaf_kind)::in,
                          ast_time_model::in, ident::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

applicability_agg(SchemaName, Slot, Value, TimeModel, Id, !Errors) :-
    Agg = Id ^ id_name,
    Where = "`series " ++ SchemaName ++ "." ++ Slot ++ "`: ",
    ( if bad_quantile(Agg) then
        !:Errors = [with_hint(error_at(dv_series_invalid_quantile,
            Id ^ id_pos,
            Where ++ "`" ++ Agg ++ "` is not a legal quantile; `pXX` takes "
                ++ "an integer in 1..99 ([LSER.17.6])"),
            "use `min` or `max` for the extreme value") | !.Errors]
    else if not lser_17_2_aggregation(Agg) then
        !:Errors = [error_at(dv_series_agg_not_supported, Id ^ id_pos,
            Where ++ "`" ++ Agg ++ "` is not an aggregation ([LSER.17.2])")
            | !.Errors]
    else if
        % The type axis, reported before the time model's ([LSER.17.7]).
        Value = yes(Leaf),
        not lser_17_2_applies(Agg, Leaf)
    then
        !:Errors = [with_hint(error_at(dv_series_agg_type_mismatch,
            Id ^ id_pos,
            Where ++ "`" ++ Agg ++ "` does not apply to a " ++ leaf_name(Leaf)
                ++ " slot ([LSER.17.2])"),
            lser_17_3_type_hint(Leaf)) | !.Errors]
    else
        Model = model_name(TimeModel),
        Support = lser_18_1_support(Agg, Model),
        (
            Support = backed
        ;
            Support = no_backing,
            !:Errors = [with_hint(error_at(dv_series_no_exact_backing,
                model_pos(TimeModel),
                Where ++ "`" ++ Agg ++ " " ++ Model
                    ++ ( if Model = "tumbling" then
                        "` is refused: no aggregation is backed on `tumbling` "
                            ++ "in this edition ([LSER.14.4.5])"
                    else
                        "` has no exact backing in v1 ([LSER.18.1])"
                    )),
                "every aggregation is exact ([LSER.10.19]), so a combination "
                    ++ "v1 cannot compute exactly is refused rather than "
                    ++ "approximated -- `sliding` backs this one")
                | !.Errors]
        ;
            Support = no_semantics,
            !:Errors = [with_hint(error_at(dv_series_agg_time_model_mismatch,
                model_pos(TimeModel),
                Where ++ "`" ++ Agg ++ "` is not defined under `"
                    ++ Model ++ "` ([LSER.18.1])"),
                "the time models `" ++ Agg ++ "` admits are "
                    ++ string.join_list(", ", list.map(quoted,
                        models_admitting(Agg))))
                | !.Errors]
        )
    ).

    %@helper
:- pred bad_quantile(string::in) is semidet.

bad_quantile(Name) :-
    string.remove_prefix("p", Name, Digits),
    string.to_int(Digits, N),
    string.from_int(N) = Digits,
    ( N < 1 ; N > 99 ).

    %@helper
:- func model_name(ast_time_model) = string.

model_name(atm_all_time(_)) = "all_time".
model_name(atm_sliding(_, _)) = "sliding".
model_name(atm_tumbling(_, _)) = "tumbling".
model_name(atm_sample(_, _)) = "sample".

    %@helper
:- func model_pos(ast_time_model) = pos.

model_pos(atm_all_time(P)) = P.
model_pos(atm_sliding(_, P)) = P.
model_pos(atm_tumbling(_, P)) = P.
model_pos(atm_sample(_, P)) = P.

%-----------------------------------------------------------------------------%
% [LSER.17.2]'s applicability matrix
%-----------------------------------------------------------------------------%

    % The equality aggregations on `Json` stand on [LSER.17.2]'s row, which
    % admits more than [LSER.17.4].
    %
    %@spec [LSER.17.2]
    %@spec [LSER.17.1]
    %@spec [LSER.17.4]
    %@spec [LSER.17.5]
    %@spec [LSIG.1.2]
    %@spec [LSIG.1.4.3]
    %@spec [LSIG.1.5.4]
:- pred lser_17_2_applies(string::in, leaf_kind::in) is semidet.

lser_17_2_applies(Agg, Leaf) :-
    ( if numeric_agg(Agg) then
        ( Leaf = lk_int ; Leaf = lk_float ; Leaf = lk_duration )
    else if boolean_agg(Agg) then
        Leaf = lk_bool
    else
        true
    ).

    %@helper
:- pred numeric_agg(string::in) is semidet.

numeric_agg(Agg) :-
    ( numeric_agg_table(Agg)
    ; quantile_fn(Agg)
    ).

    %@helper
:- pred numeric_agg_table(string::in) is semidet.

numeric_agg_table("min").
numeric_agg_table("max").
numeric_agg_table("sum").
numeric_agg_table("mean").
numeric_agg_table("median").
numeric_agg_table("variance").
numeric_agg_table("stdev").
numeric_agg_table("pvariance").
numeric_agg_table("pstdev").
numeric_agg_table("rate").
numeric_agg_table("direction").
numeric_agg_table("integral").

    %@helper
:- pred boolean_agg(string::in) is semidet.

boolean_agg("bool_and").
boolean_agg("bool_or").
boolean_agg("active_fraction").
boolean_agg("onset_rate").

    %@helper
:- func leaf_name(leaf_kind) = string.

leaf_name(lk_int) = "an `Int`".
leaf_name(lk_float) = "a `Float`".
leaf_name(lk_bool) = "a `Bool`".
leaf_name(lk_string) = "a `String`".
leaf_name(lk_bytes) = "a `Bytes`".
leaf_name(lk_json) = "a `Json`".
leaf_name(lk_time) = "a `Time`".
leaf_name(lk_date) = "a `Date`".
leaf_name(lk_duration) = "a `Duration`".
leaf_name(lk_interval(_)) = "an `Interval`".
leaf_name(lk_fact(S)) = "a `" ++ S ++ "`".
leaf_name(lk_opaque(N)) = "an opaque `" ++ N ^ dr_name ++ "`".

    %@spec [LSER.17.3]
:- func lser_17_3_type_hint(leaf_kind) = string.

lser_17_3_type_hint(Leaf) =
    ( if Leaf = lk_bool then
        "`bool_and` / `bool_or` are the `Bool` aggregations; `count` counts "
            ++ "occurrences"
    else if Leaf = lk_json then
        "project the field into a typed slot first, then aggregate that "
            ++ "([LSER.17.4])"
    else
        "use `count` for occurrences, or `count_distinct` for unique values"
    ).

%-----------------------------------------------------------------------------%
% [LSER.18.1]'s backing matrix
%-----------------------------------------------------------------------------%
%
% Only the ✗ cells are listed. Everything absent is backed.

    %@helper
:- type backing_support
    --->    backed
    ;       no_backing
    ;       no_semantics.

    %@spec [LSER.18.1]
    %@spec [LSER.18.2]
    %@spec [LSER.14.4.5]
    %@spec [LSER.15.2]
    %@spec [LSER.17.7]
    %@spec [LSIG.1.3.3]
    %@spec [LSMP.3.1]
    %@spec [LSMP.3.2]
    %@spec [LSMP.3.2a]
:- func lser_18_1_support(string, string) = backing_support.

lser_18_1_support(Agg, Model) = Support :-
    ( if no_exact_backing(Agg, Model) then
        Support = no_backing
    else if undefined_combination(Agg, Model) then
        Support = no_semantics
    else
        Support = backed
    ).

    % The footnoted ✗ cells: § (no aggregation is backed on `tumbling` in this
    % edition), † (quantiles need a bounded window), ‡ (the distinct/membership
    % set needs one too).
    %
    %@helper
:- pred no_exact_backing(string::in, string::in) is semidet.

no_exact_backing(Agg, "tumbling") :-
    % § ([LSER.14.4.5]). `active_fraction` and `onset_rate` have a refusal of
    % their own (`undefined_combination`), and this predicate is asked first.
    not bool_signal_agg(Agg).
no_exact_backing(Agg, "all_time") :-
    % † and ‡ -- the quantiles and the equality-keyed aggregations need a
    % bounded window.
    ( quantile_fn(Agg)
    ; Agg = "median"
    ; Agg = "count_distinct"
    ; Agg = "count_of"
    ; Agg = "contains"
    ).

    % The unfootnoted ✗ cells.
    %
    %@helper
:- pred undefined_combination(string::in, string::in) is semidet.

undefined_combination(Agg, "sample") :-
    ( Agg = "rate"
    ; Agg = "direction"
    ; Agg = "first"
    ; Agg = "last"
    ; Agg = "bool_and"
    ; Agg = "bool_or"
    ; Agg = "count_distinct"
    ; Agg = "count_of"
    ; Agg = "contains"
    ; signal_agg(Agg)
    ).
undefined_combination(Agg, "all_time") :-
    bool_signal_agg(Agg).
undefined_combination(Agg, "tumbling") :-
    bool_signal_agg(Agg).

    %@helper
:- pred signal_agg(string::in) is semidet.

signal_agg("active_fraction").
signal_agg("onset_rate").
signal_agg("integral").

    %@helper
:- pred bool_signal_agg(string::in) is semidet.

bool_signal_agg("active_fraction").
bool_signal_agg("onset_rate").

    %@helper
:- func models_admitting(string) = list(string).

models_admitting(Agg) =
    list.filter(admits(Agg), ["all_time", "sliding", "tumbling", "sample"]).

    %@helper
:- pred admits(string::in, string::in) is semidet.

admits(Agg, Model) :-
    lser_18_1_support(Agg, Model) = backed.

%-----------------------------------------------------------------------------%
% Label legality -- [LSER.6.12.1] and [LSER.6.8.6]
%-----------------------------------------------------------------------------%

    % `lser_6_10_2_designators` relies on this: it tells a label from a slot by
    % asking the schema.
    %
    %@spec [LSER.6.12.1]
    %@spec [LSER.6.8.7]
:- pred lser_6_12_1_label_names(resolved_file::in, string::in, ast_series::in,
                                list(diagnostic)::in, list(diagnostic)::out)
                                is det.

lser_6_12_1_label_names(RF, SchemaName, Series, !Errors) :-
    list.foldl(lser_6_12_1_label(RF, SchemaName), Series ^ asr_lines, !Errors).

    %@helper
:- pred lser_6_12_1_label(resolved_file::in, string::in, ast_series_line::in,
                          list(diagnostic)::in, list(diagnostic)::out) is det.

lser_6_12_1_label(RF, SchemaName, Line, !Errors) :-
    ( if
        Line ^ asl_as = yes(Label),
        schema_has_slot(RF, SchemaName, Label ^ id_name)
    then
        D = with_hint(error_at(dv_companion_slot_collision, Label ^ id_pos,
            "`as " ++ Label ^ id_name ++ "`: `" ++ SchemaName
                ++ "` already declares a slot called `" ++ Label ^ id_name
                ++ "`, so `<binding>." ++ Label ^ id_name
                ++ "` would name two things ([LSER.6.12.1])"),
            "rename the label"),
        !:Errors = [D | !.Errors]
    else
        true
    ).

    %@spec [LSER.6.8.6]
:- pred lser_6_8_6_label_aggs(ast_series::in,
                              list(diagnostic)::in, list(diagnostic)::out)
                              is det.

lser_6_8_6_label_aggs(Series, !Errors) :-
    list.foldl2(collect_label_aggs, Series ^ asr_lines, set.init, _, !Errors).

    %@helper
:- pred collect_label_aggs(ast_series_line::in, set(string)::in,
                           set(string)::out,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

collect_label_aggs(Line, !Seen, !Errors) :-
    ( if Line ^ asl_as = yes(Label) then
        list.foldl2(check_label_agg(Label ^ id_name, Line ^ asl_pos),
            Line ^ asl_aggs, !Seen, !Errors)
    else
        true
    ).

    %@helper
:- pred check_label_agg(string::in, pos::in, ident::in,
                        set(string)::in, set(string)::out,
                        list(diagnostic)::in, list(diagnostic)::out) is det.

check_label_agg(Label, Pos, Id, !Seen, !Errors) :-
    Key = Label ++ "." ++ Id ^ id_name,
    ( if set.contains(!.Seen, Key) then
        D = with_hint(error_at(dv_series_duplicate_decl, Pos,
            "`" ++ Id ^ id_name ++ "` is declared twice under the label `"
                ++ Label ++ "` ([LSER.6.8.6])"),
            "one line per (label, aggregation) -- merge them, or give the "
                ++ "second line its own label"),
        !:Errors = [D | !.Errors]
    else
        set.insert(Key, !Seen)
    ).

%-----------------------------------------------------------------------------%
% The observation set -- [LSER.6.9.1]
%-----------------------------------------------------------------------------%

lser_6_9_1_observations(RF, SchemaName) = Observations :-
    list.foldl(collect_observations(RF, SchemaName), RF ^ rf_ast ^ af_decls,
        [], Reversed),
    Observations = list.reverse(Reversed).

    % The resolver's diagnostics are dropped: `lser_7_1_declarations` reports
    % them.
    %
    %@helper
:- pred collect_observations(resolved_file::in, string::in, ast_decl::in,
                             list(series_obs)::in, list(series_obs)::out) is det.

collect_observations(RF, SchemaName, Decl, !Observations) :-
    ( if Decl = ad_series(Series) then
        lser_7_7_2_target(RF, Series ^ asr_slot, Series ^ asr_pos, Target,
            [], _Dropped),
        ( if Target = yes(SchemaName - Slot) then
            list.foldl(observation_of_line(Slot), Series ^ asr_lines,
                !Observations)
        else
            true
        )
    else
        true
    ).

    %@helper
:- pred observation_of_line(string::in, ast_series_line::in,
                            list(series_obs)::in, list(series_obs)::out) is det.

observation_of_line(Slot, Line, !Observations) :-
    ( if Line ^ asl_as = yes(Label) then
        MaybeLabel = yes(Label ^ id_name)
    else
        MaybeLabel = no
    ),
    Aggs = list.map(name_of_ident, Line ^ asl_aggs),
    !:Observations =
        [series_obs(Slot, MaybeLabel, Aggs, Line ^ asl_pos) | !.Observations].

    %@helper
:- func name_of_ident(ident) = string.

name_of_ident(Id) = Id ^ id_name.

%-----------------------------------------------------------------------------%
% Cursor resolution -- [LSER.6.11.1]
%-----------------------------------------------------------------------------%

lser_6_11_1_cursor(RF, SchemaName, Components, Pos) = Outcome :-
    ( if list.split_last(Components, Designators, AggId) then
        Agg = AggId ^ id_name,
        All = lser_6_9_1_observations(RF, SchemaName),
        lser_6_10_2_designators(RF, SchemaName, Designators,
            MaybeSlot, MaybeLabel),

        % Step 1 -- the slot designator, absent meaning every slot.
        ( if MaybeSlot = yes(Slot) then
            OnSlot = list.filter(observes_slot(Slot), All)
        else
            OnSlot = All
        ),

        % Step 2 -- the label, absent meaning the unlabelled lines.
        Candidates = list.filter(carries_label(MaybeLabel), OnSlot),

        % Step 3 -- the aggregation.
        Covering = list.filter(covers_agg(Agg), Candidates),
        (
            Covering = [Observation],
            Outcome = cursor_resolved(Observation, Agg)
        ;
            Covering = [],
            Outcome = cursor_failed(lser_6_9_4_absent(SchemaName, Agg,
                MaybeSlot, MaybeLabel, OnSlot, AggId ^ id_pos))
        ;
            Covering = [_, _ | _],
            Outcome = cursor_failed(lser_6_9_3_ambiguous(Agg, Covering,
                AggId ^ id_pos))
        )
    else
        % Unreachable from the type checker.
        Outcome = cursor_failed(error_at(dv_no_series_for_companion_slot, Pos,
            "a series cursor needs an aggregation ([LSER.6.10.1])"))
    ).

    %@spec [LSER.6.10.2]
    %@spec [LSER.6.12.1]
    %@spec [LSER.6.10.1]
    %@spec [LSER.6.9.6]
    %@spec [LSER.6.8.1]
:- pred lser_6_10_2_designators(resolved_file::in, string::in, list(ident)::in,
                                maybe(string)::out, maybe(string)::out) is det.

lser_6_10_2_designators(RF, SchemaName, Designators, MaybeSlot, MaybeLabel) :-
    (
        Designators = [],
        MaybeSlot = no,
        MaybeLabel = no
    ;
        Designators = [One],
        ( if schema_has_slot(RF, SchemaName, One ^ id_name) then
            MaybeSlot = yes(One ^ id_name),
            MaybeLabel = no
        else
            MaybeSlot = no,
            MaybeLabel = yes(One ^ id_name)
        )
    ;
        Designators = [SlotId, LabelId | _],
        MaybeSlot = yes(SlotId ^ id_name),
        MaybeLabel = yes(LabelId ^ id_name)
    ).

    %@helper
:- pred schema_has_slot(resolved_file::in, string::in, string::in) is semidet.

schema_has_slot(RF, SchemaName, Slot) :-
    map.search(RF ^ rf_types, SchemaName, te_schema(Schema)),
    has_slot(Schema, Slot).

    %@helper
:- pred observes_slot(string::in, series_obs::in) is semidet.

observes_slot(Slot, Observation) :-
    Observation ^ so_slot = Slot.

    %@helper
:- pred carries_label(maybe(string)::in, series_obs::in) is semidet.

carries_label(MaybeLabel, Observation) :-
    Observation ^ so_label = MaybeLabel.

    %@helper
:- pred covers_agg(string::in, series_obs::in) is semidet.

covers_agg(Agg, Observation) :-
    list.member(Agg, Observation ^ so_aggs).

%-----------------------------------------------------------------------------%

    %@spec [LSER.6.9.4]
    %@spec [LSER.6.8.4]
    %@spec [LSER.10.5]
:- func lser_6_9_4_absent(string, string, maybe(string), maybe(string),
                          list(series_obs), pos) = diagnostic.

lser_6_9_4_absent(SchemaName, Agg, MaybeSlot, MaybeLabel, OnSlot, Pos)
        = Diagnostic :-
    Where = ( if MaybeSlot = yes(Slot) then
                "`" ++ SchemaName ++ "." ++ Slot ++ "`"
              else
                "schema `" ++ SchemaName ++ "`"
            ),
    ( if
        % `t.<label>.<agg>` where the label names no line at all.
        MaybeLabel = yes(Label),
        list.filter(carries_label(yes(Label)), OnSlot) = []
    then
        Diagnostic = with_hint(error_at(dv_no_series_for_companion_slot, Pos,
            "no observation on " ++ Where ++ " is labelled `" ++ Label ++ "`"),
            available_labels(labels_of(OnSlot)))
    else if
        % `t.<agg>` where the aggregation exists, but only under labels
        % ([LSER.6.8.4], [LSER.6.8.5]).
        MaybeLabel = no,
        Under = labels_of(list.filter(covers_agg(Agg),
            list.filter(labelled, OnSlot))),
        Under = [_ | _]
    then
        Diagnostic = with_hint(error_at(dv_no_series_for_companion_slot, Pos,
            "`" ++ Agg ++ "` on " ++ Where ++ " is declared only under a "
                ++ "label, so the unlabelled companion slot does not resolve "
                ++ "([LSER.6.8.4])"),
            "name one: " ++ string.join_list(", ",
                list.map(label_read(Agg), Under)))
    else
        Diagnostic = with_hint(error_at(dv_no_series_for_companion_slot, Pos,
            "no `series` on " ++ Where ++ " declares `" ++ Agg ++ "`"),
            "declare it -- `series " ++ SchemaName ++ ".<slot>:` with a `"
                ++ Agg ++ "` line ([LSER.10.5])")
    ).

    %@helper
:- func available_labels(list(string)) = string.

available_labels([]) =
    "no observation on this schema carries a label".
available_labels([L | Ls]) =
    "the labels declared here are "
        ++ string.join_list(", ", list.map(quoted, [L | Ls])).

    %@helper
:- func quoted(string) = string.

quoted(S) = "`" ++ S ++ "`".

    %@helper
:- func label_read(string, string) = string.

label_read(Agg, Label) = "`." ++ Label ++ "." ++ Agg ++ "`".

    %@helper
:- pred labelled(series_obs::in) is semidet.

labelled(Observation) :-
    Observation ^ so_label = yes(_).

    %@helper
:- func labels_of(list(series_obs)) = list(string).

labels_of(Observations) = Labels :-
    list.foldl2(add_label, Observations, set.init, _, [], Reversed),
    Labels = list.reverse(Reversed).

    %@helper
:- pred add_label(series_obs::in, set(string)::in, set(string)::out,
                  list(string)::in, list(string)::out) is det.

add_label(Observation, !Seen, !Labels) :-
    ( if
        Observation ^ so_label = yes(Label),
        not set.contains(!.Seen, Label)
    then
        set.insert(Label, !Seen),
        !:Labels = [Label | !.Labels]
    else
        true
    ).

    %@spec [LSER.6.9.3]
:- func lser_6_9_3_ambiguous(string, list(series_obs), pos) = diagnostic.

lser_6_9_3_ambiguous(Agg, Covering, Pos) = Diagnostic :-
    Named = list.map(observation_designator(Agg), Covering),
    Slots = list.map(slot_of, Covering),
    Diagnostic = with_hint(error_at(dv_ambiguous_companion_slot, Pos,
        "`" ++ Agg ++ "` is declared by more than one series on this schema ("
            ++ string.join_list(", ", list.map(quoted, Slots)) ++ ")"),
        "qualify the cursor: " ++ string.join_list(" or ", Named)).

    %@helper
:- func slot_of(series_obs) = string.

slot_of(Observation) = Observation ^ so_slot.

    %@helper
:- func observation_designator(string, series_obs) = string.

observation_designator(Agg, Observation) = Text :-
    ( if Observation ^ so_label = yes(Label) then
        Text = "`." ++ Observation ^ so_slot ++ "." ++ Label ++ "." ++ Agg ++ "`"
    else
        Text = "`." ++ Observation ^ so_slot ++ "." ++ Agg ++ "`"
    ).

%-----------------------------------------------------------------------------%
% The aggregation vocabulary -- [LSER.17.2]
%-----------------------------------------------------------------------------%

lser_17_2_aggregation(Name) :-
    ( if aggregation_table(Name) then
        true
    else
        quantile_fn(Name)
    ).

lser_6_5_companion_aggregation(Name) :-
    lser_17_2_aggregation(Name),
    not lser_6_5_value_argument(Name).

    %@helper
:- pred lser_6_5_value_argument(string::in) is semidet.

lser_6_5_value_argument("count_of").
lser_6_5_value_argument("contains").

    %@helper
:- pred aggregation_table(string::in) is semidet.

aggregation_table("min").
aggregation_table("max").
aggregation_table("sum").
aggregation_table("mean").
aggregation_table("median").
aggregation_table("variance").
aggregation_table("stdev").
aggregation_table("pvariance").
aggregation_table("pstdev").
aggregation_table("count").
aggregation_table("count_distinct").
aggregation_table("count_of").
aggregation_table("contains").
aggregation_table("bool_and").
aggregation_table("bool_or").
aggregation_table("first").
aggregation_table("last").
aggregation_table("rate").
aggregation_table("direction").

    % [LSIG.1.1]'s three signal aggregations.
    %
    %@spec [LSIG.1.1]
aggregation_table("active_fraction").
aggregation_table("onset_rate").
aggregation_table("integral").

%-----------------------------------------------------------------------------%
% Block options and accuracy phrases -- [LSER.13.11], [LSER.15.1]
%-----------------------------------------------------------------------------%

    %@spec [LSER.13.11]
    % `DS_VALIDATE_SERIES_CAPACITY_EXCEEDS_CONTRACT` is not raised: it needs
    % `realtime`, which 1.0.0 refuses.
    %
    %@spec [LSER.13.14]
:- pred lser_13_14_capacity(ast_series::in,
                            list(diagnostic)::in, list(diagnostic)::out) is det.

lser_13_14_capacity(Series, !Errors) :-
    ( if
        list.find_first_match((pred(O::in) is semidet :-
            O = abk_capacity(_, _)), Series ^ asr_opts, abk_capacity(Tok, Pos)),
        Tok ^ tk_tok = int_lit(N)
    then
        ( if N < 1i64 then
            !:Errors = [error_at(dv_capacity_not_positive, Pos,
                "`capacity: " ++ int64_to_string(N) ++ "` must be at least 1 "
                    ++ "([LSER.13.14])") | !.Errors]
        else
            list.foldl(below_sample(N), Series ^ asr_lines, !Errors)
        )
    else
        true
    ).

    %@helper
:- pred below_sample(int64::in, ast_series_line::in,
                     list(diagnostic)::in, list(diagnostic)::out) is det.

below_sample(Cap, Line, !Errors) :-
    ( if
        Line ^ asl_time = atm_sample(ex_int(Size, _), Pos),
        Size > Cap
    then
        !:Errors = [with_hint(error_at(dv_series_capacity_below_sample, Pos,
            "`sample " ++ int64_to_string(Size) ++ "` retains "
                ++ int64_to_string(Size) ++ " samples, above the block's "
                ++ "`capacity: " ++ int64_to_string(Cap) ++ "` ([LSER.13.14])"),
            "raise `capacity:` to at least the sample size, or sample fewer")
            | !.Errors]
    else
        true
    ).

:- pred lser_13_11_duplicate_options(list(ast_block_kwarg)::in,
                                     list(diagnostic)::in,
                                     list(diagnostic)::out) is det.

lser_13_11_duplicate_options(Options, !Errors) :-
    list.foldl2(option_once, Options, set.init, _, !Errors).

    %@helper
:- pred option_once(ast_block_kwarg::in, set(string)::in, set(string)::out,
                    list(diagnostic)::in, list(diagnostic)::out) is det.

option_once(Option, !Seen, !Errors) :-
    (
        Option = abk_persist(_, Pos),
        Name = "persist"
    ;
        Option = abk_by(_, Pos),
        Name = "by"
    ;
        Option = abk_capacity(_, Pos),
        Name = "capacity"
    ;
        Option = abk_nulls(_, Pos),
        Name = "nulls"
    ),
    ( if set.contains(!.Seen, Name) then
        !:Errors = [error_at(dv_series_duplicate_kwarg, Pos,
            "`" ++ Name ++ ":` is given twice in this `series` declaration "
                ++ "([LSER.13.11])") | !.Errors]
    else
        set.insert(Name, !Seen)
    ).

    % `exact` is refused too ([LGRA.7.1]). No accuracy clause names this code.
    %
    %@spec [LSER.15.1]
:- pred lser_15_1_accuracy(ast_series_line::in,
                           list(diagnostic)::in, list(diagnostic)::out) is det.

lser_15_1_accuracy(Line, !Errors) :-
    ( if Line ^ asl_accuracy = yes(Accuracy) then
        accuracy_phrase(Accuracy, Phrase, Pos),
        !:Errors = [with_hint(error_at(dv_series_no_exact_backing, Pos,
            "`" ++ Phrase ++ "` is an accuracy phrase, and v1 has none: every "
                ++ "series aggregation is exact ([LSER.15.1])"),
            "drop the phrase; a combination with no exact backing is refused "
                ++ "on its own ([LSER.15.2])") | !.Errors]
    else
        true
    ).

    %@helper
:- pred accuracy_phrase(ast_accuracy::in, string::out, pos::out) is det.

accuracy_phrase(aac_exact(P), "exact", P).
accuracy_phrase(aac_tolerance(_, P), "tolerance", P).
accuracy_phrase(aac_confidence(_, P), "confidence", P).
accuracy_phrase(aac_delta(_, P), "delta", P).
accuracy_phrase(aac_bound_deterministic(P), "bound deterministic", P).

%-----------------------------------------------------------------------------%
:- end_module dsc.series.
%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc_rules -- decoding the rule-metadata atoms into `rule_meta`.
%
% These atoms precede the `TerminalNode` atoms they name, so this accumulates and
% resolves at the end [RDSC.8.3]. The join key is the rule name alone
% ([LGRA.6.8]); `module_id` takes no part in it.
%-----------------------------------------------------------------------------%

:- module ds.dsc_rules.
:- interface.

:- import_module ds.atom.
:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.network.
:- import_module ds.rules.
:- import_module ds.wire.
:- import_module list.

%-----------------------------------------------------------------------------%

:- type rules_staging.

:- func init_rules_staging = rules_staging.

:- type rules_step
    --->    rs_ok(rules_staging, intern_table)
    ;       rs_error(load_error_kind, string).

:- pred rule_atom(atom_id::in) is semidet.

:- pred decode_rule_atom(atom_id::in, reader::in, rules_staging::in,
                         intern_table::in, rules_step::out) is det.

:- type rules_result
    --->    rules_ok(list(rule_meta))
    ;       rules_failed(load_error_kind, string).

    % A terminal's ordinal is its position in `Terminals`.
    %
    %@spec [RDSC.8.4]
:- pred resolve_rule_meta(rules_staging::in, list(terminal_node)::in,
                          rules_result::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.chrono.
:- import_module ds.id.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

    % Every atom is optional.
    %
:- type raw_meta
    --->    raw_meta(
                rw_cool    :: maybe(uint64),
                rw_where   :: maybe(source_pos),
                rw_display :: maybe(string),
                rw_clip    :: maybe(uint32)
            ).

:- func blank_meta = raw_meta.

blank_meta = raw_meta(no, no, no, no).

:- type rules_staging
    --->    rules_staging(
                rg_meta  :: map(uint32, raw_meta)
                            % Keyed on the interned rule name's ref.
            ).

init_rules_staging = rules_staging(map.init).

%-----------------------------------------------------------------------------%

rule_atom(at_rule_cooldown).
rule_atom(at_rule_source).
rule_atom(at_rule_debug_name).

decode_rule_atom(A, Body, Rg0, IT0, Step) :-
    ( if A = at_rule_debug_name then
        with_string_field(Body, 2u32, Rg0, IT0, set_display, Step)
    else if A = at_rule_cooldown then
        with_varint_field(Body, 2u32, Rg0, IT0, set_cool, Step)
    else if A = at_rule_source then
        decode_srcr(Body, Rg0, IT0, Step)
    else
        Step = rs_error(lek_decode, "RDSC.6.3")
    ).

    % `rule_name` 1, one payload field, `module_id` 10.
    %
:- type meta_acc
    --->    meta_acc(
                ma_name :: string,
                ma_str  :: string,
                ma_int  :: uint64,
                ma_clip :: uint32
            ).

:- pred with_string_field(reader, uint32, rules_staging, intern_table,
                          pred(string, raw_meta, raw_meta), rules_step).
:- mode with_string_field(in, in, in, in, pred(in, in, out) is det, out) is det.

with_string_field(R, Field, Rg0, IT0, Apply, Step) :-
    fold_meta(R, Field, Result),
    (
        Result = ff_ok(A),
        % A second atom for one rule replaces the first's field ([RDSC.7.2]).
        Closure = (pred(M0::in, M::out) is det :-
            Apply(A ^ ma_str, M0, M)),
        record(A, Closure, Rg0, IT0, Step)
    ;
        Result = ff_bad_field,
        Step = rs_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_wire(_),
        Step = rs_error(lek_decode, "RDSC.11.1")
    ).

:- pred with_varint_field(reader, uint32, rules_staging, intern_table,
                          pred(uint64, raw_meta, raw_meta), rules_step).
:- mode with_varint_field(in, in, in, in, pred(in, in, out) is det, out) is det.

with_varint_field(R, Field, Rg0, IT0, Apply, Step) :-
    fold_meta(R, Field, Result),
    (
        Result = ff_ok(A),
        Closure = (pred(M0::in, M::out) is det :-
            Apply(A ^ ma_int, M0, M)),
        record(A, Closure, Rg0, IT0, Step)
    ;
        Result = ff_bad_field,
        Step = rs_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_wire(_),
        Step = rs_error(lek_decode, "RDSC.11.1")
    ).

:- pred fold_meta(reader::in, uint32::in, fold_result(meta_acc)::out) is det.

fold_meta(R, Field, Result) :-
    fold_fields(R, meta_field(Field), meta_acc("", "", 0u64, 0u32), Result).

:- pred meta_field(uint32::in, uint32::in, field_value::in,
                   meta_acc::in, meta_acc::out) is semidet.

meta_field(Want, Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, N), A = A0 ^ ma_name := N
    else if Num = 10u32 then
        Value = fv_varint(V), A = A0 ^ ma_clip := uint32.cast_from_uint64(V)
    else if Num = Want then
        ( if Value = fv_bytes(S2) then
            reader_string(S2, Str), A = A0 ^ ma_str := Str
        else
            Value = fv_varint(V2), A = A0 ^ ma_int := V2
        )
    else
        A = A0
    ).

:- pred record(meta_acc, pred(raw_meta, raw_meta), rules_staging,
               intern_table, rules_step).
:- mode record(in, pred(in, out) is det, in, in, out) is det.

record(A, Apply, Rg0, IT0, rs_ok(Rg, IT)) :-
    intern(A ^ ma_name, Ref, IT0, IT),
    Key = intern_ref_value(Ref),
    Base = ( if map.search(Rg0 ^ rg_meta, Key, Prior) then Prior
        else blank_meta ),
    Apply(Base, Updated),
    WithClip = ( if Updated ^ rw_clip = no then
        Updated ^ rw_clip := yes(A ^ ma_clip) else Updated ),
    Rg = rules_staging(map.set(Rg0 ^ rg_meta, Key, WithClip)).

:- pred set_display(string::in, raw_meta::in, raw_meta::out) is det.
:- pred set_cool(uint64::in, raw_meta::in, raw_meta::out) is det.

set_display(V, !M) :- !M ^ rw_display := yes(V).
set_cool(V, !M) :- !M ^ rw_cool := yes(V).

    % Its own fold: two payload fields, `line` 3 and `col` 4. `module_id` names the
    % file through its `DsSource`.
    %
:- pred decode_srcr(reader::in, rules_staging::in, intern_table::in,
                    rules_step::out) is det.

decode_srcr(R, Rg0, IT0, Step) :-
    fold_fields(R, srcr_field, {"", 0u32, 0u32, 0u32}, Result),
    (
        Result = ff_ok({Name, Line, Col, Clip}),
        Where = source_pos(Line, Col, Clip),
        Closure = (pred(M0::in, M::out) is det :-
            M = M0 ^ rw_where := yes(Where)),
        record(meta_acc(Name, "", 0u64, Clip), Closure, Rg0, IT0, Step)
    ;
        Result = ff_bad_field,
        Step = rs_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_wire(_),
        Step = rs_error(lek_decode, "RDSC.11.1")
    ).

:- pred srcr_field(uint32::in, field_value::in,
    {string, uint32, uint32, uint32}::in,
    {string, uint32, uint32, uint32}::out) is semidet.

srcr_field(Num, Value, {Name0, Line0, Col0, Clip0}, Acc) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, Name),
        Acc = {Name, Line0, Col0, Clip0}
    else if Num = 3u32 then
        Value = fv_varint(V), Acc = {Name0, uint32.cast_from_uint64(V), Col0, Clip0}
    else if Num = 4u32 then
        Value = fv_varint(V), Acc = {Name0, Line0, uint32.cast_from_uint64(V), Clip0}
    else if Num = 10u32 then
        Value = fv_varint(V), Acc = {Name0, Line0, Col0, uint32.cast_from_uint64(V)}
    else
        Acc = {Name0, Line0, Col0, Clip0}
    ).

%-----------------------------------------------------------------------------%
% Resolution
%-----------------------------------------------------------------------------%

resolve_rule_meta(Rg, Terminals, Result) :-
    ( if rdsc_8_7_rule_group_dangles(Rg, Terminals) then
        Result = rules_failed(lek_dangling, "RDSC.8.7")
    else
        build_metas(Terminals, Rg, 0, [], Result)
    ).

    % A check of its own: `build_metas` walks the terminals, so metadata naming
    % none is never visited.
    %
    %@spec [RDSC.8.7]
:- pred rdsc_8_7_rule_group_dangles(rules_staging::in, list(terminal_node)::in)
    is semidet.

rdsc_8_7_rule_group_dangles(Rg, Terminals) :-
    Realized = set.list_to_set(
        list.map((func(T) = intern_ref_value(T ^ tn_rule)), Terminals)),
    map.keys(Rg ^ rg_meta, Named),
    list.find_first_match((pred(K::in) is semidet :-
        not set.member(K, Realized)), Named, _).

:- pred build_metas(list(terminal_node)::in, rules_staging::in, int::in,
                    list(rule_meta)::in, rules_result::out) is det.

build_metas([], _, _, Acc, rules_ok(list.reverse(Acc))).
build_metas([T | Ts], Rg, Position, Acc, Result) :-
    Key = intern_ref_value(T ^ tn_rule),
    Raw = ( if map.search(Rg ^ rg_meta, Key, R) then R else blank_meta ),
    ( if source_index(Position, Source) then
        Meta = rule_meta(T ^ tn_id, T ^ tn_rule, Source,
            rate_of(Raw), T ^ tn_guard, Raw ^ rw_display, Raw ^ rw_where),
        build_metas(Ts, Rg, Position + 1, [Meta | Acc], Result)
    else
        Result = rules_failed(lek_semantic, "RLOW.14.3")
    ).

    % `window_ns = 0` means no window.
    %
:- func rate_of(raw_meta) = rate_config.

rate_of(Raw) = rate_config(window(Raw ^ rw_cool)).

:- func window(maybe(uint64)) = maybe(duration).

window(no) = no.
window(yes(Ns)) =
    ( if Ns = 0u64 then no else yes(duration_from_ns(Ns)) ).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc_expr -- decoding the RETE expression tree.
%
% Most `Expr` arms are sub-messages differing only in which field numbers hold
% what, so one walker, `parse_parts`, is driven by a table of field shapes per
% message. `interp` has its own walk.
%-----------------------------------------------------------------------------%

:- module ds.dsc_expr.
:- interface.

:- import_module ds.expr.
:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.wire.

%-----------------------------------------------------------------------------%

:- type expr_result
    --->    xr_ok(expr, intern_table)
    ;       xr_error(load_error_kind, string).      % kind, clause id

    % The `bind_scope` is the terminal's `bind_count`, or `no_bind_frame` for a
    % `BetaNode`'s join tests. A bind index is kept whatever the frame
    % [RDSC.4a.9.6]: the evaluator, which knows the frame's size, faults on one
    % outside it.
    %
:- pred decode_expr(reader::in, bind_scope::in, intern_table::in,
                    expr_result::out) is det.

    % [RDSC.11.3], the outermost at depth 0.
    %
:- func max_expr_depth = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.builtins.
:- import_module ds.chrono.
:- import_module ds.id.
:- import_module ds.value.
:- import_module bool.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

max_expr_depth = 48.

decode_expr(R, Scope, IT, Result) :-
    decode_expr_at(R, 0, Scope, IT, Result).

:- pred decode_expr_at(reader::in, int::in, bind_scope::in, intern_table::in,
                       expr_result::out) is det.

decode_expr_at(R, Depth, Scope, IT, Result) :-
    ( if Depth > max_expr_depth then
        Result = xr_error(lek_semantic, "RDSC.11.3")
    else
        expr_fields(R, Depth, Scope, m_none, no, IT, Result)
    ).

    % The oneof member so far. A NaN `lit_float` is refused only if it is still
    % the member when the body ends [RDSC.9.10].
    %
:- type member
    --->    m_none
    ;       m_expr(expr)
    ;       m_nan.

    % Of two oneof members, the last is held ([RDSC.9.5]). `ds.dsc_judge` has
    % refused a message member arriving twice, and judged the whole body's decode
    % ([RDSC.11.4]), which is what lets this return the first refusal it meets.
    %
    % `json_tainted`, field 19, is outside the oneof, so is applied at the end.
    %
:- pred expr_fields(reader::in, int::in, bind_scope::in, member::in,
                    bool::in, intern_table::in, expr_result::out) is det.

expr_fields(R0, Depth, Scope, Kind0, Tainted0, IT0, Result) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        (
            Kind0 = m_expr(E),
            (
                Tainted0 = yes,
                Result = xr_ok(e_tainted(E), IT0)
            ;
                Tainted0 = no,
                Result = xr_ok(E, IT0)
            )
        ;
            Kind0 = m_nan,
            Result = xr_error(lek_semantic, "RDSC.9.10")
        ;
            Kind0 = m_none,
            Result = xr_error(lek_semantic, "RDSC.11.3")
        )
    ;
        F = field_error(_),
        Result = xr_error(lek_decode, "RDSC.11.1")
    ;
        F = field(Num, Value),
        expr_field(Num, Value, Depth, Scope, IT0, Field),
        (
            Field = xf_error(K, C),
            Result = xr_error(K, C)
        ;
            Field = xf_ignored,
            expr_fields(R1, Depth, Scope, Kind0, Tainted0, IT0, Result)
        ;
            Field = xf_taint(Tainted),
            expr_fields(R1, Depth, Scope, Kind0, Tainted, IT0, Result)
        ;
            Field = xf_nan,
            expr_fields(R1, Depth, Scope, m_nan, Tainted0, IT0, Result)
        ;
            Field = xf_ok(E, IT1),
            expr_fields(R1, Depth, Scope, m_expr(E), Tainted0, IT1, Result)
        )
    ).

:- type xfield
    --->    xf_ok(expr, intern_table)
    ;       xf_nan
    ;       xf_taint(bool)
    ;       xf_ignored
    ;       xf_error(load_error_kind, string).

:- func bad_field = xfield.

bad_field = xf_error(lek_decode, "RDSC.11.1").

:- pred expr_field(uint32::in, field_value::in, int::in, bind_scope::in,
                   intern_table::in, xfield::out) is det.

expr_field(Num, Value, Depth, Scope, IT, Out) :-
    ( if Num = 1u32 then
        % `int64`: a sign-extended varint, not zigzag.
        ( if Value = fv_varint(V) then
            Out = xf_ok(e_lit(int(int64.cast_from_uint64(V))), IT)
        else
            Out = bad_field
        )
    else if Num = 2u32 then
        % `float_from_bits` would read a NaN as 0.0.
        ( if Value = fv_fixed64(V) then
            ( if nan_bits(V) then
                Out = xf_nan
            else
                Out = xf_ok(e_lit(float(float_from_bits(V))), IT)
            )
        else
            Out = bad_field
        )
    else if Num = 3u32 then
        ( if Value = fv_bytes(S), reader_string(S, Str) then
            intern(Str, Ref, IT, IT1),
            Out = xf_ok(e_lit(str(Ref)), IT1)
        else
            Out = bad_field
        )
    else if Num = 4u32 then
        ( if Value = fv_varint(V) then
            Out = xf_ok(e_lit(bool(bool_of(V))), IT)
        else
            Out = bad_field
        )
    else if Num = 11u32 then
        % `now`: the oneof case is the signal, and the bool payload means nothing.
        ( if Value = fv_varint(_) then
            Out = xf_ok(e_now, IT)
        else
            Out = bad_field
        )
    else if Num = 21u32 then
        % `entry_stamp` [LTIM.2.8.6]: a pattern index as VarExpr's.
        ( if Value = fv_varint(V) then
            ( if wire_fact_index(wire_uint32(V), Fact) then
                Out = xf_ok(e_entry_stamp(Fact), IT)
            else
                Out = xf_error(lek_semantic, "RDSC.4a.9.1")
            )
        else
            Out = bad_field
        )
    else if Num = 16u32 then
        % `lit_null`: as for `now`.
        ( if Value = fv_varint(_) then
            Out = xf_ok(e_lit(null), IT)
        else
            Out = bad_field
        )
    else if Num = 14u32 then
        % [RDSC.4a.9.6]: kept whatever the frame; one outside it faults where it
        % is read.
        ( if Value = fv_varint(V) then
            Out = xf_ok(e_bind_ref(bind_index_of(wire_uint32(V))), IT)
        else
            Out = bad_field
        )
    else if Num = 22u32 then
        % `lit_time` [RLOW.6.1.8]: UTC nanoseconds, a sign-extended varint, at
        % offset 0.
        ( if Value = fv_varint(V) then
            Out = xf_ok(e_lit(time(ds_time(int64.cast_from_uint64(V), 0i64))), IT)
        else
            Out = bad_field
        )
    else if Num = 19u32 then
        % `json_tainted`.
        ( if Value = fv_varint(V) then
            Out = xf_taint(bool_of(V))
        else
            Out = bad_field
        )
    else if sub_message(Num, Decode) then
        ( if Value = fv_bytes(Sub) then
            Decode(Sub, Depth + 1, Scope, IT, Out)
        else
            Out = bad_field
        )
    else
        Out = xf_ignored
    ).

:- pred sub_message(uint32, pred(reader, int, bind_scope, intern_table,
                                 xfield)).
:- mode sub_message(in, out(pred(in, in, in, in, out) is det)) is semidet.

sub_message(5u32,  decode_var).
sub_message(6u32,  decode_binop).
sub_message(7u32,  decode_unop).
sub_message(8u32,  decode_call).
sub_message(12u32, decode_if).
sub_message(13u32, decode_bind).
sub_message(15u32, decode_json_path).
sub_message(17u32, decode_coalesce).
sub_message(18u32, decode_is_test).
sub_message(20u32, decode_interp).

%-----------------------------------------------------------------------------%
% The generic body walker
%-----------------------------------------------------------------------------%

:- type field_shape
    --->    fs_int
    ;       fs_str
    ;       fs_expr
    ;       fs_rep_expr.

:- type parts
    --->    parts(
                pt_ints  :: map(uint32, uint64),
                pt_strs  :: map(uint32, string),
                pt_exprs :: map(uint32, expr),
                pt_reps  :: map(uint32, list(expr)),    % REVERSED; see below
                pt_it    :: intern_table
            ).

:- type parts_result
    --->    pp_ok(parts)
    ;       pp_error(load_error_kind, string).

:- func init_parts(intern_table) = parts.

init_parts(IT) = parts(map.init, map.init, map.init, map.init, IT).

:- pred parse_parts(reader, pred(uint32, field_shape), int, bind_scope,
                    parts, parts_result).
:- mode parse_parts(in, pred(in, out) is semidet, in, in, in, out) is det.

parse_parts(R0, Shape, Depth, Scope, P0, Result) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        Result = pp_ok(P0)
    ;
        F = field_error(_),
        Result = pp_error(lek_decode, "RDSC.11.1")
    ;
        F = field(Num, Value),
        ( if Shape(Num, Kind) then
            parse_part(Num, Kind, Value, Depth, Scope, P0, Step),
            (
                Step = pp_error(_, _),
                Result = Step
            ;
                Step = pp_ok(P1),
                parse_parts(R1, Shape, Depth, Scope, P1, Result)
            )
        else
            parse_parts(R1, Shape, Depth, Scope, P0, Result)
        )
    ).

:- pred parse_part(uint32::in, field_shape::in, field_value::in, int::in,
                   bind_scope::in, parts::in, parts_result::out) is det.

parse_part(Num, fs_int, Value, _, _, P0, Result) :-
    ( if Value = fv_varint(V) then
        Result = pp_ok(P0 ^ pt_ints := map.set(P0 ^ pt_ints, Num, V))
    else
        Result = pp_error(lek_decode, "RDSC.11.1")
    ).
parse_part(Num, fs_str, Value, _, _, P0, Result) :-
    ( if Value = fv_bytes(S), reader_string(S, Str) then
        Result = pp_ok(P0 ^ pt_strs := map.set(P0 ^ pt_strs, Num, Str))
    else
        Result = pp_error(lek_decode, "RDSC.11.1")
    ).
parse_part(Num, fs_expr, Value, Depth, Scope, P0, Result) :-
    ( if Value = fv_bytes(Sub) then
        decode_expr_at(Sub, Depth, Scope, P0 ^ pt_it, Sub_Result),
        (
            Sub_Result = xr_error(K, C),
            Result = pp_error(K, C)
        ;
            Sub_Result = xr_ok(E, IT),
            Result = pp_ok(((P0 ^ pt_exprs := map.set(P0 ^ pt_exprs, Num, E))
                ^ pt_it := IT))
        )
    else
        Result = pp_error(lek_decode, "RDSC.11.1")
    ).
parse_part(Num, fs_rep_expr, Value, Depth, Scope, P0, Result) :-
    ( if Value = fv_bytes(Sub) then
        decode_expr_at(Sub, Depth, Scope, P0 ^ pt_it, Sub_Result),
        (
            Sub_Result = xr_error(K, C),
            Result = pp_error(K, C)
        ;
            Sub_Result = xr_ok(E, IT),
            Prior = ( if map.search(P0 ^ pt_reps, Num, L) then L else [] ),
            Result = pp_ok(((P0 ^ pt_reps :=
                map.set(P0 ^ pt_reps, Num, [E | Prior])) ^ pt_it := IT))
        )
    else
        Result = pp_error(lek_decode, "RDSC.11.1")
    ).

:- func repeated(parts, uint32) = list(expr).

repeated(P, Num) =
    ( if map.search(P ^ pt_reps, Num, L) then list.reverse(L) else [] ).

    % proto3 omits a zero: `BinopOp` zero is `BINOP_ADD`.
    %
:- func int_part(parts, uint32) = uint64.

int_part(P, Num) = ( if map.search(P ^ pt_ints, Num, V) then V else 0u64 ).

%-----------------------------------------------------------------------------%
% The sub-messages
%-----------------------------------------------------------------------------%

:- pred decode_var(reader::in, int::in, bind_scope::in, intern_table::in,
                   xfield::out) is det.

:- pred var_shape(uint32::in, field_shape::out) is semidet.

var_shape(1u32, fs_int).        % pattern_index
var_shape(2u32, fs_int).        % slot_index

decode_var(R, Depth, Scope, IT, Out) :-
    parse_parts(R, var_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        % [RDSC.4a.9.1]: one past 255 is refused, not truncated.
        Pattern = wire_uint32(int_part(P, 1u32)),
        Slot = wire_uint32(int_part(P, 2u32)),
        ( if
            wire_fact_index(Pattern, FactIx),
            wire_slot_read(Slot, Read)
        then
            Out = xf_ok(e_slot(FactIx, Read), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.4a.9.1")
        )
    ).

:- pred decode_binop(reader::in, int::in, bind_scope::in, intern_table::in,
                     xfield::out) is det.

:- pred binop_shape(uint32::in, field_shape::out) is semidet.

binop_shape(1u32, fs_int).      % op
binop_shape(2u32, fs_expr).     % left
binop_shape(3u32, fs_expr).     % right

decode_binop(R, Depth, Scope, IT, Out) :-
    parse_parts(R, binop_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            rete_binop(int_part(P, 1u32), Op),
            map.search(P ^ pt_exprs, 2u32, Left),
            map.search(P ^ pt_exprs, 3u32, Right)
        then
            Out = xf_ok(e_binop(Op, Left, Right), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_unop(reader::in, int::in, bind_scope::in, intern_table::in,
                    xfield::out) is det.

:- pred unop_shape(uint32::in, field_shape::out) is semidet.

unop_shape(1u32, fs_int).       % op
unop_shape(2u32, fs_expr).      % operand

decode_unop(R, Depth, Scope, IT, Out) :-
    parse_parts(R, unop_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            rete_unop(int_part(P, 1u32), Op),
            map.search(P ^ pt_exprs, 2u32, Operand)
        then
            Out = xf_ok(e_unop(Op, Operand), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_call(reader::in, int::in, bind_scope::in, intern_table::in,
                    xfield::out) is det.

:- pred call_shape(uint32::in, field_shape::out) is semidet.

call_shape(2u32, fs_rep_expr).  % args
call_shape(3u32, fs_int).       % op

decode_call(R, Depth, Scope, IT, Out) :-
    parse_parts(R, call_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        Wire = uint32.cast_from_uint64(int_part(P, 3u32)),
        ( if builtin_fn(Wire, Fn) then
            Out = xf_ok(e_call(Fn, repeated(P, 2u32)), P ^ pt_it)
        else
            Out = xf_error(rejection_kind(why_rejected(Wire)), "RDSC.4a.9.3")
        )
    ).

%-----------------------------------------------------------------------------%
% InterpExpr
%-----------------------------------------------------------------------------%

    % `InterpExpr { repeated FormatPrim prims = 1; }`. [IARC.1.16]'s loader half.
    % How a spec's parts combine with its type is the compiler's to refuse.
    %
:- pred decode_interp(reader::in, int::in, bind_scope::in, intern_table::in,
                      xfield::out) is det.

decode_interp(R, Depth, Scope, IT, Out) :-
    interp_prims(R, Depth, Scope, IT, [], Out).

:- pred interp_prims(reader::in, int::in, bind_scope::in, intern_table::in,
                     list(format_prim)::in, xfield::out) is det.

interp_prims(R0, Depth, Scope, IT0, Acc, Out) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        Out = xf_ok(e_interp(list.reverse(Acc)), IT0)
    ;
        F = field_error(_),
        Out = bad_field
    ;
        F = field(Num, Value),
        ( if Num = 1u32 then
            ( if Value = fv_bytes(Sub) then
                format_prim(Sub, Depth, Scope, IT0, PrimOut),
                (
                    PrimOut = po_ok(Prim, IT1),
                    interp_prims(R1, Depth, Scope, IT1, [Prim | Acc], Out)
                ;
                    PrimOut = po_error(K, C),
                    Out = xf_error(K, C)
                )
            else
                Out = bad_field
            )
        else
            interp_prims(R1, Depth, Scope, IT0, Acc, Out)
        )
    ).

:- type prim_out
    --->    po_ok(format_prim, intern_table)
    ;       po_error(load_error_kind, string).

:- func interp_refused = prim_out.

interp_refused = po_error(lek_semantic, "IARC.1.16").

    % `FormatPrim { oneof prim { string text = 1; ValuePrim value = 2;
    % TimePrim time = 3; } }`.
    %
:- pred format_prim(reader::in, int::in, bind_scope::in, intern_table::in,
                    prim_out::out) is det.

format_prim(R, Depth, Scope, IT, Out) :-
    format_prim_fields(R, Depth, Scope, IT, no, Out).

:- pred format_prim_fields(reader::in, int::in, bind_scope::in,
                           intern_table::in, maybe(format_prim)::in,
                           prim_out::out) is det.

format_prim_fields(R0, Depth, Scope, IT0, Prim0, Out) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        (
            Prim0 = yes(Prim),
            Out = po_ok(Prim, IT0)
        ;
            Prim0 = no,
            Out = interp_refused
        )
    ;
        F = field_error(_),
        Out = po_error(lek_decode, "RDSC.11.1")
    ;
        F = field(Num, Value),
        ( if Num = 1u32 then
            ( if Value = fv_bytes(S), reader_string(S, Text) then
                format_prim_fields(R1, Depth, Scope, IT0, yes(fp_text(Text)),
                    Out)
            else
                Out = po_error(lek_decode, "RDSC.11.1")
            )
        else if Num = 2u32 then
            ( if Value = fv_bytes(Sub) then
                value_prim(Sub, Depth, Scope, IT0, VOut),
                (
                    VOut = po_ok(Prim, IT1),
                    format_prim_fields(R1, Depth, Scope, IT1, yes(Prim), Out)
                ;
                    VOut = po_error(_, _),
                    Out = VOut
                )
            else
                Out = po_error(lek_decode, "RDSC.11.1")
            )
        else if Num = 3u32 then
            ( if Value = fv_bytes(Sub) then
                time_prim(Sub, Depth, Scope, IT0, TOut),
                (
                    TOut = po_ok(Prim, IT1),
                    format_prim_fields(R1, Depth, Scope, IT1, yes(Prim), Out)
                ;
                    TOut = po_error(_, _),
                    Out = TOut
                )
            else
                Out = po_error(lek_decode, "RDSC.11.1")
            )
        else
            format_prim_fields(R1, Depth, Scope, IT0, Prim0, Out)
        )
    ).

    % `ValuePrim`: `value` 1, `align` 2, `plus` 3, `zero` 4, `width` 5,
    % `has_precision` 6, `precision` 7, `type` 8.
    %
:- pred value_shape(uint32::in, field_shape::out) is semidet.

value_shape(1u32, fs_expr).
value_shape(2u32, fs_int).
value_shape(3u32, fs_int).
value_shape(4u32, fs_int).
value_shape(5u32, fs_int).
value_shape(6u32, fs_int).
value_shape(7u32, fs_int).
value_shape(8u32, fs_int).

:- pred value_prim(reader::in, int::in, bind_scope::in, intern_table::in,
                   prim_out::out) is det.

value_prim(R, Depth, Scope, IT, Out) :-
    parse_parts(R, value_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = po_error(K, C)
    ;
        Result = pp_ok(P),
        Plus = bool_of(int_part(P, 3u32)),
        Zero = bool_of(int_part(P, 4u32)),
        ( if
            format_align_of(wire_uint32(int_part(P, 2u32)), Align),
            format_type_of(wire_uint32(int_part(P, 8u32)), Type)
        then
            ( if map.search(P ^ pt_exprs, 1u32, Value) then
                Precision = ( if bool_of(int_part(P, 6u32)) = yes then
                                yes(wire_uint32(int_part(P, 7u32)))
                              else no ),
                Out = po_ok(fp_value(value_prim(Value, Align, Plus, Zero,
                    wire_uint32(int_part(P, 5u32)), Precision, Type)),
                    P ^ pt_it)
            else
                Out = po_error(lek_semantic, "RDSC.11.1")
            )
        else
            Out = interp_refused
        )
    ).

    % A `uint32` field as protobuf-c reads it: the varint TRUNCATED to its low
    % 32 bits.
    %
:- func wire_uint32(uint64) = uint32.

wire_uint32(V) = uint32.cast_from_uint64(V /\ 0xFFFFFFFFu64).

    % A value past the last member, or a negative one, fails and is refused.
    %
:- pred format_align_of(uint32::in, format_align::out) is semidet.

format_align_of(0u32, align_default).
format_align_of(1u32, align_left).
format_align_of(2u32, align_right).

:- pred format_type_of(uint32::in, format_type::out) is semidet.

format_type_of(0u32, ft_canonical).
format_type_of(1u32, ft_d).
format_type_of(2u32, ft_f).
format_type_of(3u32, ft_s).
format_type_of(4u32, ft_x_lower).
format_type_of(5u32, ft_x_upper).
format_type_of(6u32, ft_b).

    % `TimePrim { Expr value = 1; repeated TimeItem items = 2; }`.
    %
:- pred time_prim(reader::in, int::in, bind_scope::in, intern_table::in,
                  prim_out::out) is det.

time_prim(R, Depth, Scope, IT, Out) :-
    time_prim_fields(R, Depth, Scope, IT, no, [], Out).

:- pred time_prim_fields(reader::in, int::in, bind_scope::in, intern_table::in,
                         maybe(expr)::in, list(time_item)::in, prim_out::out)
    is det.

time_prim_fields(R0, Depth, Scope, IT0, Value0, Items, Out) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        (
            Value0 = yes(Value),
            Out = po_ok(fp_time(Value, list.reverse(Items)), IT0)
        ;
            Value0 = no,
            Out = po_error(lek_semantic, "RDSC.11.1")
        )
    ;
        F = field_error(_),
        Out = po_error(lek_decode, "RDSC.11.1")
    ;
        F = field(Num, FValue),
        ( if Num = 1u32 then
            ( if FValue = fv_bytes(Sub) then
                % The `Expr` arm that reached this body counted the level.
                decode_expr_at(Sub, Depth, Scope, IT0, SubResult),
                (
                    SubResult = xr_ok(E, IT1),
                    time_prim_fields(R1, Depth, Scope, IT1, yes(E), Items, Out)
                ;
                    SubResult = xr_error(K, C),
                    Out = po_error(K, C)
                )
            else
                Out = po_error(lek_decode, "RDSC.11.1")
            )
        else if Num = 2u32 then
            ( if FValue = fv_bytes(Sub) then
                time_item(Sub, ti_none, ItemOut),
                (
                    ItemOut = yes(Item),
                    time_prim_fields(R1, Depth, Scope, IT0, Value0,
                        [Item | Items], Out)
                ;
                    ItemOut = no,
                    Out = interp_refused
                )
            else
                Out = po_error(lek_decode, "RDSC.11.1")
            )
        else
            time_prim_fields(R1, Depth, Scope, IT0, Value0, Items, Out)
        )
    ).

    % `TimeItem { oneof item { string text = 1; TimeField field = 2; } }`.
    % `no` is a refusal. The field's value is judged after the walk, since the
    % member that counts is the last.
    %
:- type raw_item
    --->    ti_none
    ;       ti_raw_text(string)
    ;       ti_raw_field(uint64).

:- pred time_item(reader::in, raw_item::in, maybe(time_item)::out) is det.

time_item(R0, Item0, Out) :-
    next_field(F, R0, R1),
    (
        F = fields_end,
        (
            Item0 = ti_none,
            Out = no
        ;
            Item0 = ti_raw_text(Text),
            Out = yes(ti_text(Text))
        ;
            Item0 = ti_raw_field(V),
            ( if time_field_of(wire_uint32(V), Field) then
                Out = yes(ti_field(Field))
            else
                Out = no
            )
        )
    ;
        F = field_error(_),
        Out = no
    ;
        F = field(Num, Value),
        ( if Num = 1u32 then
            ( if Value = fv_bytes(S), reader_string(S, Text) then
                time_item(R1, ti_raw_text(Text), Out)
            else
                Out = no
            )
        else if Num = 2u32 then
            ( if Value = fv_varint(V) then
                time_item(R1, ti_raw_field(V), Out)
            else
                Out = no
            )
        else
            time_item(R1, Item0, Out)
        )
    ).

:- pred time_field_of(uint32::in, time_field::out) is semidet.

time_field_of(1u32, tf_year).
time_field_of(2u32, tf_month).
time_field_of(3u32, tf_day).
time_field_of(4u32, tf_hour).
time_field_of(5u32, tf_minute).
time_field_of(6u32, tf_second).
time_field_of(7u32, tf_microsecond).
time_field_of(8u32, tf_utc_offset).

:- pred decode_if(reader::in, int::in, bind_scope::in, intern_table::in,
                  xfield::out) is det.

:- pred if_shape(uint32::in, field_shape::out) is semidet.

if_shape(1u32, fs_expr).        % cond
if_shape(2u32, fs_expr).        % then_
if_shape(3u32, fs_expr).        % else_

decode_if(R, Depth, Scope, IT, Out) :-
    parse_parts(R, if_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            map.search(P ^ pt_exprs, 1u32, Cond),
            map.search(P ^ pt_exprs, 2u32, Then),
            map.search(P ^ pt_exprs, 3u32, Else)
        then
            Out = xf_ok(e_if(Cond, Then, Else), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_bind(reader::in, int::in, bind_scope::in, intern_table::in,
                    xfield::out) is det.

:- pred bind_shape(uint32::in, field_shape::out) is semidet.

bind_shape(1u32, fs_int).       % bind_index
bind_shape(2u32, fs_expr).      % expr

decode_bind(R, Depth, Scope, IT, Out) :-
    parse_parts(R, bind_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if map.search(P ^ pt_exprs, 2u32, Bound) then
            % [RDSC.4a.9.6]: kept whatever the frame; one outside it faults
            % where it is written.
            Ix = bind_index_of(wire_uint32(int_part(P, 1u32))),
            Out = xf_ok(e_bind(Ix, Bound), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_json_path(reader::in, int::in, bind_scope::in, intern_table::in,
                         xfield::out) is det.

:- pred json_path_shape(uint32::in, field_shape::out) is semidet.

json_path_shape(1u32, fs_expr). % val
json_path_shape(2u32, fs_expr). % path

decode_json_path(R, Depth, Scope, IT, Out) :-
    parse_parts(R, json_path_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            map.search(P ^ pt_exprs, 1u32, Val),
            map.search(P ^ pt_exprs, 2u32, Path)
        then
            Out = xf_ok(e_json_path_expr(Val, Path), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_coalesce(reader::in, int::in, bind_scope::in, intern_table::in,
                        xfield::out) is det.

:- pred coalesce_shape(uint32::in, field_shape::out) is semidet.

coalesce_shape(1u32, fs_expr).  % left
coalesce_shape(2u32, fs_expr).  % right

decode_coalesce(R, Depth, Scope, IT, Out) :-
    parse_parts(R, coalesce_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            map.search(P ^ pt_exprs, 1u32, Left),
            map.search(P ^ pt_exprs, 2u32, Right)
        then
            Out = xf_ok(e_coalesce(Left, Right), P ^ pt_it)
        else
            Out = xf_error(lek_semantic, "RDSC.11.1")
        )
    ).

:- pred decode_is_test(reader::in, int::in, bind_scope::in, intern_table::in,
                       xfield::out) is det.

:- pred is_test_shape(uint32::in, field_shape::out) is semidet.

is_test_shape(1u32, fs_expr).   % operand
is_test_shape(2u32, fs_int).    % subject (IsSubject)
is_test_shape(3u32, fs_int).    % negated (bool -> varint)

decode_is_test(R, Depth, Scope, IT, Out) :-
    parse_parts(R, is_test_shape, Depth, Scope, init_parts(IT), Result),
    (
        Result = pp_error(K, C),
        Out = xf_error(K, C)
    ;
        Result = pp_ok(P),
        ( if
            map.search(P ^ pt_exprs, 1u32, Operand),
            is_subject_of(int_part(P, 2u32), Subject)
        then
            Negated = ( if int_part(P, 3u32) = 0u64 then no else yes ),
            Out = xf_ok(e_is_test(Operand, Subject, Negated), P ^ pt_it)
        else
            % A subject outside the set, proto3's omitted zero included.
            Out = xf_error(lek_semantic, "LNUL.4.9")
        )
    ).

%-----------------------------------------------------------------------------%
% The operator tables
%-----------------------------------------------------------------------------%

    % `rete_expr.BinopOp`. `**` is the `FN_POW` call.
    %
:- pred rete_binop(uint64::in, binop::out) is semidet.

rete_binop(0u64,  op_add).
rete_binop(1u64,  op_sub).
rete_binop(2u64,  op_mul).
rete_binop(3u64,  op_div).
rete_binop(4u64,  op_floordiv).
rete_binop(5u64,  op_rem).
rete_binop(6u64,  op_eq).
rete_binop(7u64,  op_ne).
rete_binop(8u64,  op_lt).
rete_binop(9u64,  op_gt).
rete_binop(10u64, op_le).
rete_binop(11u64, op_ge).
rete_binop(12u64, op_and).
rete_binop(13u64, op_or).
rete_binop(14u64, op_bit_and).
rete_binop(15u64, op_bit_or).
rete_binop(16u64, op_bit_xor).
rete_binop(17u64, op_shl).
rete_binop(18u64, op_shr).

    % `rete_expr.IsSubject` [LNUL.4.9].
    %
:- pred is_subject_of(uint64::in, is_subject::out) is semidet.

is_subject_of(1u64,  is_null).
is_subject_of(2u64,  is_true).
is_subject_of(3u64,  is_false).
is_subject_of(4u64,  is_inf).
is_subject_of(5u64,  is_neg_inf).
is_subject_of(6u64,  is_nan).
is_subject_of(7u64,  is_int).
is_subject_of(8u64,  is_float).
is_subject_of(9u64,  is_bool).
is_subject_of(10u64, is_string).
is_subject_of(11u64, is_bytes).
is_subject_of(12u64, is_json).

    % `rete_expr.UnopOp`.
    %
:- pred rete_unop(uint64::in, unop::out) is semidet.

rete_unop(0u64, op_not).
rete_unop(1u64, op_bitnot).
rete_unop(2u64, op_neg).

%-----------------------------------------------------------------------------%

:- func rejection_kind(rejected_fn) = load_error_kind.

rejection_kind(_) = lek_fn_not_found.

:- func bool_of(uint64) = bool.

bool_of(V) = ( if V = 0u64 then no else yes ).

%-----------------------------------------------------------------------------%

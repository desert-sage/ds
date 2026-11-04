% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.dsc_network -- decoding AlphaNode / BetaNode / TerminalNode into a Rete network.
%
% References can point forward, so every node is staged with them bare, and
% ds.network resolves them at commit.
%-----------------------------------------------------------------------------%

:- module ds.dsc_network.
:- interface.

:- import_module ds.fault.
:- import_module ds.intern.
:- import_module ds.network.
:- import_module ds.wire.

%-----------------------------------------------------------------------------%

:- type network_staging.

:- func init_network_staging = network_staging.

:- type network_step
    --->    ns_ok(network_staging, intern_table)
    ;       ns_error(load_error_kind, string).      % kind, clause id

:- pred decode_alfa(reader::in, network_staging::in, intern_table::in,
                    network_step::out) is det.
:- pred decode_beta(reader::in, network_staging::in, intern_table::in,
                    network_step::out) is det.
:- pred decode_term(reader::in, network_staging::in, intern_table::in,
                    network_step::out) is det.

:- pred resolve_staged_network(network_staging::in, network_result::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.dsc_action.
:- import_module ds.dsc_expr.
:- import_module ds.dsc_judge.
:- import_module ds.expr.
:- import_module ds.id.
:- import_module ds.schema.
:- import_module bool.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

    % Reverse encounter order, restored at resolve.
    %
:- type network_staging
    --->    network_staging(
                ng_alphas :: list(raw_alpha),
                ng_betas  :: list(raw_beta),
                ng_terms  :: list(raw_terminal)
            ).

init_network_staging = network_staging([], [], []).

%-----------------------------------------------------------------------------%
% [RDSC.11.4]: decoded before judged
%-----------------------------------------------------------------------------%

:- pred judged(judge_root::in, reader::in, maybe(network_step)::out) is det.

judged(Root, R, Refusal) :-
    J = rdsc_11_4_judge(Root, R),
    (
        J = j_decodes,
        Refusal = no
    ;
        J = j_undecodable,
        Refusal = yes(ns_error(lek_decode, "RDSC.11.1"))
    ;
        J = j_repeated,
        Refusal = yes(ns_error(lek_decode, "RDSC.9.5"))
    ;
        J = j_bad_string,
        Refusal = yes(ns_error(lek_decode, "RDSC.9.12"))
    ;
        J = j_too_deep,
        Refusal = yes(ns_error(lek_semantic, "RDSC.11.3"))
    ).

decode_alfa(R, Ng0, IT0, Step) :-
    judged(jr_alpha_node, R, Refusal),
    (
        Refusal = yes(Step)
    ;
        Refusal = no,
        decode_alfa_body(R, Ng0, IT0, Step)
    ).

decode_beta(R, Ng0, IT0, Step) :-
    judged(jr_beta_node, R, Refusal),
    (
        Refusal = yes(Step)
    ;
        Refusal = no,
        decode_beta_body(R, Ng0, IT0, Step)
    ).

decode_term(R, Ng0, IT0, Step) :-
    judged(jr_terminal_node, R, Refusal),
    (
        Refusal = yes(Step)
    ;
        Refusal = no,
        decode_term_body(R, Ng0, IT0, Step)
    ).

resolve_staged_network(Ng, Result) :-
    resolve_network(list.reverse(Ng ^ ng_alphas), list.reverse(Ng ^ ng_betas),
        list.reverse(Ng ^ ng_terms), Result).

%-----------------------------------------------------------------------------%
% AlphaNode
%-----------------------------------------------------------------------------%

    % Sub-messages are captured as readers during the fold and decoded afterwards,
    % throughout this module: a `semidet` handler cannot carry a decode error out,
    % and a `TerminalNode`'s `bind_count` may arrive after what it bounds.
    %
:- type alfa_acc
    --->    alfa_acc(
                aa_id     :: uint32,
                aa_schema :: string,
                aa_tests  :: list(reader)       % reversed
            ).

:- pred decode_alfa_body(reader::in, network_staging::in, intern_table::in,
                         network_step::out) is det.

decode_alfa_body(R, Ng0, IT0, Step) :-
    fold_fields(R, alfa_field, alfa_acc(0u32, "", []), Result),
    (
        Result = ff_wire(_),
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_bad_field,
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_ok(Acc),
        ( if node_id(Acc ^ aa_id, Id) then
            ( if Acc ^ aa_schema = "" then
                Step = ns_error(lek_semantic, "RDSC.4a.6")
            else
                intern(Acc ^ aa_schema, NameRef, IT0, IT1),
                decode_alpha_tests(list.reverse(Acc ^ aa_tests), [], IT1,
                    TestResult),
                (
                    TestResult = at_error(Kind, Clause),
                    Step = ns_error(Kind, Clause)
                ;
                    TestResult = at_ok(Tests, IT),
                    Raw = raw_alpha(Id, make_schema_name(NameRef), Tests),
                    Step = ns_ok(Ng0 ^ ng_alphas :=
                        [Raw | Ng0 ^ ng_alphas], IT)
                )
            )
        else
            % Zero is the reserved null.
            Step = ns_error(lek_retp_invalid, "RDSC.4a.3")
        )
    ).

:- pred alfa_field(uint32::in, field_value::in, alfa_acc::in, alfa_acc::out)
    is semidet.

alfa_field(Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), A = A0 ^ aa_id := uint32.cast_from_uint64(V)
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, Name), A = A0 ^ aa_schema := Name
    else if Num = 3u32 then
        Value = fv_bytes(Sub), A = A0 ^ aa_tests := [Sub | A0 ^ aa_tests]
    else
        A = A0
    ).

:- type alpha_tests_result
    --->    at_ok(list(alpha_test), intern_table)
    ;       at_error(load_error_kind, string).

:- pred decode_alpha_tests(list(reader)::in, list(alpha_test)::in,
                           intern_table::in, alpha_tests_result::out) is det.

decode_alpha_tests([], Acc, IT, at_ok(list.reverse(Acc), IT)).
decode_alpha_tests([R | Rs], Acc, IT0, Result) :-
    decode_alpha_test(R, IT0, One),
    (
        One = at1_error(Kind, Clause),
        Result = at_error(Kind, Clause)
    ;
        One = at1_ok(Test, IT1),
        decode_alpha_tests(Rs, [Test | Acc], IT1, Result)
    ).

:- type alpha_test_result
    --->    at1_ok(alpha_test, intern_table)
    ;       at1_error(load_error_kind, string).

    % A raw literal, before its string is interned.
    %
:- type raw_lit
    --->    rlit_int(int64)
    ;       rlit_float(float)
    ;       rlit_str(string)
    ;       rlit_bool(bool).

:- type test_acc
    --->    test_acc(
                ta_kind    :: uint64,
                ta_slot    :: uint32,
                ta_op      :: uint64,
                ta_literal :: maybe(raw_lit),
                ta_nan     :: bool,
                ta_pattern :: string
            ).

:- pred decode_alpha_test(reader::in, intern_table::in,
                          alpha_test_result::out) is det.

decode_alpha_test(R, IT0, Result) :-
    fold_fields(R, test_field, test_acc(0u64, 0u32, 0u64, no, no, ""),
        Folded),
    (
        Folded = ff_wire(_),
        Result = at1_error(lek_decode, "RDSC.11.1")
    ;
        Folded = ff_bad_field,
        Result = at1_error(lek_decode, "RDSC.11.1")
    ;
        Folded = ff_ok(A),
        ( if wire_slot_strict(A ^ ta_slot, Slot) then
            % The slot, then the kind and what it needs, and last a NaN literal:
            % the order libds's `decode_alfa` checks in.
            build_alpha_test(A, Slot, IT0, Built),
            ( if
                Built = at1_ok(_, _),
                A ^ ta_nan = yes
            then
                Result = at1_error(lek_semantic, "RDSC.9.10")
            else
                Result = Built
            )
        else
            Result = at1_error(lek_semantic, "RDSC.4a.6.1")
        )
    ).

:- pred test_field(uint32::in, field_value::in, test_acc::in, test_acc::out)
    is semidet.

test_field(Num, Value, A0, A) :-
    % `kind` and `op` are enums: 32-bit varints, read to their low 32 bits.
    ( if Num = 1u32 then
        Value = fv_varint(V), A = A0 ^ ta_kind := V /\ 0xFFFFFFFFu64
    else if Num = 2u32 then
        Value = fv_varint(V), A = A0 ^ ta_slot := uint32.cast_from_uint64(V)
    else if Num = 3u32 then
        Value = fv_varint(V), A = A0 ^ ta_op := V /\ 0xFFFFFFFFu64
    else if Num = 4u32 then
        Value = fv_bytes(Sub), decode_alpha_literal(Sub, MaybeLit, IsNaN),
        A1 = A0 ^ ta_literal := MaybeLit,
        A = A1 ^ ta_nan := IsNaN
    else if Num = 5u32 then
        Value = fv_bytes(S), reader_string(S, P), A = A0 ^ ta_pattern := P
    else
        A = A0
    ).

:- pred build_alpha_test(test_acc::in, slot_index::in, intern_table::in,
                         alpha_test_result::out) is det.

build_alpha_test(A, Slot, IT0, Result) :-
    ( if A ^ ta_kind = 0u64 then
        % ALPHA_TEST_EQ is zero, and takes no `op`.
        need_literal(A, Slot, IT0, at_eq, Result)
    else if A ^ ta_kind = 1u64 then
        ( if alpha_cmp(A ^ ta_op, Op) then
            need_literal(A, Slot, IT0, at_cmp_with(Op), Result)
        else
            Result = at1_error(lek_semantic, "RDSC.4a.6.1")
        )
    else if A ^ ta_kind = 2u64 then
        ( if A ^ ta_pattern = "" then
            % RE2 compiles "", so `ds.dsc.invalid_alpha_regex` would not refuse it.
            Result = at1_error(lek_semantic, "RDSC.4a.6.1")
        else
            Result = at1_ok(at_regex(Slot, A ^ ta_pattern), IT0)
        )
    else
        Result = at1_error(lek_semantic, "RDSC.4a.6.1")
    ).

:- type test_builder
    --->    at_eq
    ;       at_cmp_with(binop).

:- pred need_literal(test_acc::in, slot_index::in, intern_table::in,
                     test_builder::in, alpha_test_result::out) is det.

need_literal(A, Slot, IT0, Builder, Result) :-
    (
        A ^ ta_literal = no,
        Result = at1_error(lek_semantic, "RDSC.4a.6.1")
    ;
        A ^ ta_literal = yes(Raw),
        intern_lit(Raw, Lit, IT0, IT),
        (
            Builder = at_eq,
            Result = at1_ok(at_eq(Slot, Lit), IT)
        ;
            Builder = at_cmp_with(Op),
            Result = at1_ok(at_cmp(Slot, Op, Lit), IT)
        )
    ).

:- pred intern_lit(raw_lit::in, alpha_literal::out,
                   intern_table::in, intern_table::out) is det.

intern_lit(rlit_int(I), al_int(I), !IT).
intern_lit(rlit_float(F), al_float(F), !IT).
intern_lit(rlit_bool(B), al_bool(B), !IT).
intern_lit(rlit_str(S), al_string(Ref), !IT) :-
    intern(S, Ref, !IT).

    % A literal with no member set is `no`, as an absent field 4 is. Fails only on
    % a wire error.
    %
    % `IsNaN`: the winning member is a NaN [RDSC.9.10]. The literal is then a
    % `rlit_float(0.0)` standing for it, so the kind checks see a literal before
    % `decode_alpha_test` refuses it.
    %
:- pred decode_alpha_literal(reader::in, maybe(raw_lit)::out, bool::out)
    is semidet.

decode_alpha_literal(R, MaybeLit, IsNaN) :-
    fold_fields(R, literal_field, {no, no}, Result),
    Result = ff_ok({MaybeLit, IsNaN}).

:- pred literal_field(uint32::in, field_value::in,
                      {maybe(raw_lit), bool}::in, {maybe(raw_lit), bool}::out)
    is semidet.

literal_field(Num, Value, L0, L) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), L = {yes(rlit_int(int64.cast_from_uint64(V))), no}
    else if Num = 2u32 then
        Value = fv_fixed64(V),
        ( if nan_bits(V) then
            L = {yes(rlit_float(0.0)), yes}
        else
            L = {yes(rlit_float(float_from_bits(V))), no}
        )
    else if Num = 3u32 then
        Value = fv_bytes(S), reader_string(S, Str), L = {yes(rlit_str(Str)), no}
    else if Num = 4u32 then
        Value = fv_varint(V), L = {yes(rlit_bool(bool_of(V))), no}
    else
        L = L0
    ).

    % `alfa.AlphaCmpOp`, numbered apart from `rete_expr.BinopOp`.
    %
:- pred alpha_cmp(uint64::in, binop::out) is semidet.

alpha_cmp(0u64, op_eq).
alpha_cmp(1u64, op_ne).
alpha_cmp(2u64, op_lt).
alpha_cmp(3u64, op_gt).
alpha_cmp(4u64, op_le).
alpha_cmp(5u64, op_ge).

%-----------------------------------------------------------------------------%
% BetaNode
%-----------------------------------------------------------------------------%

:- type beta_acc
    --->    beta_acc(
                ba_id       :: uint32,
                ba_right    :: uint32,
                ba_parent   :: uint32,
                ba_tests    :: list(reader),    % reversed
                ba_negative :: bool
            ).

:- pred decode_beta_body(reader::in, network_staging::in, intern_table::in,
                         network_step::out) is det.

decode_beta_body(R, Ng0, IT0, Step) :-
    fold_fields(R, beta_field, beta_acc(0u32, 0u32, 0u32, [], no), Result),
    (
        Result = ff_wire(_),
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_bad_field,
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_ok(A),
        ( if node_id(A ^ ba_id, Id) then
            decode_exprs(list.reverse(A ^ ba_tests), no_bind_frame, [], IT0,
                TestResult),
            (
                TestResult = xs_error(Kind, Clause),
                Step = ns_error(Kind, Clause)
            ;
                TestResult = xs_ok(Tests, IT),
                Raw = raw_beta(Id, A ^ ba_right, A ^ ba_parent, Tests,
                    A ^ ba_negative),
                Step = ns_ok(Ng0 ^ ng_betas := [Raw | Ng0 ^ ng_betas], IT)
            )
        else
            Step = ns_error(lek_retp_invalid, "RDSC.4a.3")
        )
    ).

    % `right_alpha_id` and `left_parent_id` stay raw: ds.network tells a root beta
    % from a dangling reference.
    %
:- pred beta_field(uint32::in, field_value::in, beta_acc::in, beta_acc::out)
    is semidet.

beta_field(Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), A = A0 ^ ba_id := uint32.cast_from_uint64(V)
    else if Num = 2u32 then
        Value = fv_varint(V), A = A0 ^ ba_right := uint32.cast_from_uint64(V)
    else if Num = 3u32 then
        Value = fv_varint(V), A = A0 ^ ba_parent := uint32.cast_from_uint64(V)
    else if Num = 4u32 then
        Value = fv_bytes(Sub), A = A0 ^ ba_tests := [Sub | A0 ^ ba_tests]
    else if Num = 5u32 then
        Value = fv_varint(V), A = A0 ^ ba_negative := bool_of(V)
    else
        A = A0
    ).

:- type exprs_result
    --->    xs_ok(list(expr), intern_table)
    ;       xs_error(load_error_kind, string).

:- pred decode_exprs(list(reader)::in, bind_scope::in, list(expr)::in,
                     intern_table::in, exprs_result::out) is det.

decode_exprs([], _, Acc, IT, xs_ok(list.reverse(Acc), IT)).
decode_exprs([R | Rs], Scope, Acc, IT0, Result) :-
    decode_expr(R, Scope, IT0, One),
    (
        One = xr_error(Kind, Clause),
        Result = xs_error(Kind, Clause)
    ;
        One = xr_ok(E, IT1),
        decode_exprs(Rs, Scope, [E | Acc], IT1, Result)
    ).

%-----------------------------------------------------------------------------%
% TerminalNode
%-----------------------------------------------------------------------------%

:- type term_acc
    --->    term_acc(
                ta_id       :: uint32,
                ta_parent   :: uint32,
                ta_rule     :: string,
                ta_binds    :: uint32,
                ta_guard    :: maybe(reader),   % field 7
                ta_inline   :: int,             % count of field 6
                ta_actions  :: list(reader)     % field 6 bodies, reversed
            ).

:- pred decode_term_body(reader::in, network_staging::in, intern_table::in,
                         network_step::out) is det.

decode_term_body(R, Ng0, IT0, Step) :-
    Blank = term_acc(0u32, 0u32, "", 0u32, no, 0, []),
    fold_fields(R, term_field, Blank, Result),
    (
        Result = ff_wire(_),
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_bad_field,
        Step = ns_error(lek_decode, "RDSC.11.1")
    ;
        Result = ff_ok(A),
        ( if node_id(A ^ ta_id, Id) then
            build_term(Id, A, Ng0, IT0, Step)
        else
            Step = ns_error(lek_retp_invalid, "RDSC.4a.3")
        )
    ).

:- pred build_term(node_id::in, term_acc::in, network_staging::in,
                   intern_table::in, network_step::out) is det.

build_term(Id, A, Ng0, IT0, Step) :-
    % An empty `rule_name` is not refused ([RDSC.9.9]).
    intern(A ^ ta_rule, RuleRef, IT0, IT1),
    Binds = uint32.cast_to_int(A ^ ta_binds),
    decode_guard(A ^ ta_guard, bind_frame(Binds), IT1, GuardResult),
    (
        GuardResult = g_error(Kind, Clause),
        Step = ns_error(Kind, Clause)
    ;
        GuardResult = g_ok(Guard, IT2),
        decode_actions(list.reverse(A ^ ta_actions),
            bind_frame(Binds), [], IT2, ActResult),
        (
            ActResult = da_error(Kind, Clause),
            Step = ns_error(Kind, Clause)
        ;
            ActResult = da_ok(Actions, IT),
            Raw = raw_terminal(Id, A ^ ta_parent, RuleRef, Binds,
                Guard, A ^ ta_inline, Actions),
            Step = ns_ok(Ng0 ^ ng_terms := [Raw | Ng0 ^ ng_terms], IT)
        )
    ).

:- type decode_actions_result
    --->    da_ok(list(inline_action), intern_table)
    ;       da_error(load_error_kind, string).

:- pred decode_actions(list(reader)::in, bind_scope::in,
                       list(inline_action)::in, intern_table::in,
                       decode_actions_result::out) is det.

decode_actions([], _, Acc, IT, da_ok(list.reverse(Acc), IT)).
decode_actions([R | Rs], Scope, Acc, IT0, Result) :-
    decode_action(R, Scope, IT0, One),
    (
        One = ia_error(Kind, Clause),
        Result = da_error(Kind, Clause)
    ;
        One = ia_ok(A, IT1),
        decode_actions(Rs, Scope, [A | Acc], IT1, Result)
    ).

:- pred term_field(uint32::in, field_value::in, term_acc::in, term_acc::out)
    is semidet.

term_field(Num, Value, A0, A) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), A = A0 ^ ta_id := uint32.cast_from_uint64(V)
    else if Num = 2u32 then
        Value = fv_varint(V), A = A0 ^ ta_parent := uint32.cast_from_uint64(V)
    else if Num = 3u32 then
        Value = fv_bytes(S), reader_string(S, N), A = A0 ^ ta_rule := N
    else if Num = 4u32 then
        Value = fv_varint(V), A = A0 ^ ta_binds := uint32.cast_from_uint64(V)
    else if Num = 7u32 then
        Value = fv_bytes(Sub), A = A0 ^ ta_guard := yes(Sub)
    else if Num = 6u32 then
        Value = fv_bytes(Sub),
        A = ((A0 ^ ta_inline := A0 ^ ta_inline + 1)
                ^ ta_actions := [Sub | A0 ^ ta_actions])
    else
        A = A0
    ).

:- type guard_result
    --->    g_ok(maybe(expr), intern_table)
    ;       g_error(load_error_kind, string).

:- pred decode_guard(maybe(reader)::in, bind_scope::in, intern_table::in,
                     guard_result::out) is det.

decode_guard(no, _, IT, g_ok(no, IT)).
decode_guard(yes(R), Scope, IT0, Result) :-
    decode_expr(R, Scope, IT0, One),
    (
        One = xr_error(Kind, Clause),
        Result = g_error(Kind, Clause)
    ;
        One = xr_ok(E, IT),
        Result = g_ok(yes(E), IT)
    ).

%-----------------------------------------------------------------------------%

:- func bool_of(uint64) = bool.

bool_of(V) = ( if V = 0u64 then no else yes ).

%-----------------------------------------------------------------------------%

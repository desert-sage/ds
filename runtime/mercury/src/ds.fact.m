% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.fact -- facts and working-memory entries.
%-----------------------------------------------------------------------------%

:- module ds.fact.
:- interface.
:- import_module ds.fault.

:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.chrono.
:- import_module ds.value.
:- import_module array.
:- import_module list.
:- import_module maybe.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type fact
    --->    fact(
                f_id       :: fact_id,
                f_schema   :: schema_id,
                f_slots    :: array(ds_value),
                f_asserted :: instant,
                f_deadline :: maybe(instant),
                            % Independent of lifecycle: `yes` for a ttl fact and
                            % a logical fact with an override.

                f_tms      :: tms_linkage,
                f_hydrated :: hydration_tag,
                f_stamp    :: maybe(fact_stamp)
                            % `no` until the step that asserted it ends, where
                            % `ds.engine` stamps it.
            ).

    % What a fact needs to leave the engine as a FactExternal ([RFCS.23.5]). The
    % seq is its first FactAssert's ([LFST.5.6]), issued by `ds.effect`'s
    % recorder at append.
    %
:- type fact_stamp
    --->    fact_stamp(
                fs_seq  :: uint64,
                fs_wall :: maybe(int64)
            ).

%-----------------------------------------------------------------------------%
% Truth-maintenance linkage
%-----------------------------------------------------------------------------%

    % Keyed on the assertion verb, not the schema: only a fact asserted `logical`
    % is TMS-linked [LLOG.15.1], [LLOG.15.2]. The justifications are in ds.tms.
    %
:- type tms_linkage
    --->    tms_none
    ;       tms_derived.

%-----------------------------------------------------------------------------%
% Hydration
%-----------------------------------------------------------------------------%

    % The `hydrated_corr` tag [RHIM.2], lifted out of the slot array so an empty
    % correlation cannot reach the supersede sweep. The slot stays on the wire
    % and in the schema.
    %
:- type hydration_tag
    --->    live
    ;       hydrated(intern_ref).   % never the interned empty string

%-----------------------------------------------------------------------------%
% Assertion
%-----------------------------------------------------------------------------%

    % Which of [LTIM.10.9]'s conditions a `TimeZoneOffset` row broke.
    %
:- type tz_row_fault
    --->    tzf_empty_period
            % `valid_from` is not before `valid_until`.
    ;       tzf_offset_range
            % `offset_s` below -64800 or above 64800.
    ;       tzf_utc_zone.
            % The zone is exactly "UTC", which no row resolves ([LTIM.10.8]).

:- func ltim_10_9_message(tz_row_fault) = string.

    % The outcome of asserting into working memory. Every `refused_*` is a step of
    % [NFCT.2.11], the host door's alone unless it says otherwise.
    %
:- type assert_result
    --->    inserted(fact_id)
    ;       noop(fact_id)
            % No event, dwell preserved [LFAC.2.5.1].

    ;       rejected(cap)
            % Usage would exceed a cap, so the assert did not happen and the
            % engine carries on.

    ;       invalid(int, slot_reason)
            % A slot value the schema does not admit, on the host's and a rule's
            % path alike. At the host door it records nothing ([NFCT.2.11]); on a
            % rule's path it is a TypeError ([RARC.5.2.7]), but for a Json limit.

    ;       refused_halted(engine_error)
            % The tier has halted ([LERR.1] rung 7, [NCBK.2.9]). Carries the
            % error that latched.

    ;       refused_arity(int, int)
            % [NFCT.2.2]: the slot count and the number of values given.

    ;       refused_unregistered(schema_name)
            % [NFCT.1.1]: a schema this engine's artefact did not declare.

    ;       refused_time_range(int)
            % [LTIM.1.2.2]: the index of a `Date` slot outside its range.

    ;       refused_encoding(int)
            % [LSTR.8.5]: the index of a slot holding text that is not
            % well-formed UTF-8.

    ;       refused_tz_row(tz_row_fault)
            % [LTIM.10.9]: a malformed `TimeZoneOffset` row.

    ;       refused_ttl_range
            % A deadline outside the `Time` range: the fact's ([RFCS.6.7]), or a
            % held seed's the assert's sample would fix ([NLFC.9.5]). Checked
            % before the sample, so the call takes no step.

    ;       replaced(fact_id, fact_id).
            % old, new: a fresh fact_id, and exactly one live fact [LFAC.2.5.3].
            % The assert is recorded before the withdrawal it causes.

    % Compares against the one stored value: tolerance is not transitive, so
    % idempotence needs that no history is kept
    % [formal/alloy/noop_reassert.als].
    %
:- pred slot_unchanged(tolerance::in, ds_value::in, ds_value::in) is semidet.

%-----------------------------------------------------------------------------%
% Retraction
%-----------------------------------------------------------------------------%

    % Why a fact left working memory: `FactWithdraw.Cause` [RFCS.7a.2], but for
    % `rc_explicit`, a host retract, which is a FactRetract, and the two ttl
    % causes, both `TTL_EXPIRED`.
    %
:- type retract_cause
    --->    rc_explicit

    ;       rc_justifier_end
            % The fact became unsupported [IRET.12.2].

    ;       rc_ttl

    ;       rc_hydration_ttl
            % A hydrated fact's `retain:` expiry.

    ;       rc_supersede
            % Supersedure generally: an identity upsert [LFAC.2.5.3], an `as`-keyed
            % re-fire [LCRS.6.2], a superseding-correlation sweep [RHIM.5.2.1].

            % No disconnected-adapter cause: `FactWithdraw.Cause` 4 is reserved.

    ;       rc_synthetic_discharged
            % A fact the lowering created whose deferred action has run.

    ;       rc_author_withdrawn
            % A rule's own `withdraw <binding>`.

    ;       rc_activation_completed.
            % A `scope activation` fact whose activation completed ([LSCP.2.4.1]).

%-----------------------------------------------------------------------------%
% Identity
%-----------------------------------------------------------------------------%

    % A fact's key slots; `no` for a `ttl` schema, which has no identity.
    %
:- func identity_of(schema, fact) = maybe(fact_identity).

    % The first slot value the schema does not admit, with its index; fails when
    % every value is admissible. Kinds and nulls, then NaN, then the Json limits,
    % each over every slot before the next begins ([NFCT.2.11], steps 4 to 6).
    %
:- pred slot_fault(schema::in, list(ds_value)::in, int::out, slot_reason::out)
    is semidet.

    % [NFCT.2.3], [NFCT.2.11] step 4: the first fact reference `Wrong(Declared, Id)`
    % refuses, ahead of any slot the kind pass refuses. The host's door only.
    %
:- pred slot_ref_fault(pred(schema_name, fact_id)::in(pred(in, in) is semidet),
                       schema::in, list(ds_value)::in, int::out) is semidet.

    % [LSTR.11.3]: the first `String` longer than its slot's `capacity`, as the
    % capacity and its length in codepoints. A bounds refusal, not a slot fault.
    %
:- pred lstr_11_3_over_capacity(intern_table::in, schema::in,
                                list(ds_value)::in,
                                uint32::out, uint64::out) is semidet.

    % [LTIM.1.2.2]: the index of the first `Date` slot outside the Date range.
    % The host's door only, so not an arm of `slot_fault`.
    %
:- pred ltim_1_2_2_first_date_out_of_range(schema::in, list(ds_value)::in,
                                          int::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module float.
:- import_module int.
:- import_module ds.i64.
:- import_module ds.json.
:- import_module string.

ltim_10_9_message(tzf_empty_period) =
    "TimeZoneOffset: valid_from is not before valid_until ([LTIM.10.9])".
ltim_10_9_message(tzf_offset_range) =
    "TimeZoneOffset: offset_s outside [-64800, 64800] ([LTIM.10.9])".
ltim_10_9_message(tzf_utc_zone) =
    "TimeZoneOffset: the zone \"UTC\" takes no row ([LTIM.10.8], [LTIM.10.9])".

lstr_11_3_over_capacity(Interns, Schema, Values, Cap, Len) :-
    first_over_capacity(Interns, slot_commons(Schema), Values, Cap, Len).

:- pred first_over_capacity(intern_table::in, list(slot_common)::in,
                            list(ds_value)::in, uint32::out, uint64::out)
    is semidet.

first_over_capacity(Interns, [C | Cs], [V | Vs], Cap, Len) :-
    ( if
        C ^ sc_capacity = at_most(N),
        ( V = str(Ref), expand(Interns, Ref, S)
        ; V = text(S)
        ),
        L = uint64.det_from_int(string.count_codepoints(S)),
        L > uint32.cast_to_uint64(N)
    then
        Cap = N,
        Len = L
    else
        first_over_capacity(Interns, Cs, Vs, Cap, Len)
    ).

ltim_1_2_2_first_date_out_of_range(Schema, Values, Index) :-
    first_date_out_of_range(slot_commons(Schema), Values, 0, Index).

:- pred first_date_out_of_range(list(slot_common)::in, list(ds_value)::in,
                                int::in, int::out) is semidet.

first_date_out_of_range([C | Cs], [V | Vs], I, Index) :-
    ( if
        C ^ sc_kind = k_date,
        V = int(Days),
        not ltim_1_2_2_date_in_range(Days)
    then
        Index = I
    else
        first_date_out_of_range(Cs, Vs, I + 1, Index)
    ).

identity_of(Schema, Fact) = project_identity(Schema, Fact ^ f_slots).

%-----------------------------------------------------------------------------%


slot_unchanged(exact, A, B) :-
    A = B.
slot_unchanged(within(T), int(A), int(B)) :-
    abs(i64.to_float(A) - i64.to_float(B)) =< T.
    % Exact first: two equal infinities have a NaN delta.
slot_unchanged(within(T), float(A), float(B)) :-
    ( A = B
    ; abs(A - B) =< T
    ).

slot_unchanged(within(_), str(A), str(B)) :- A = B.
slot_unchanged(within(_), bool(A), bool(B)) :- A = B.
slot_unchanged(within(_), null, null).

%-----------------------------------------------------------------------------%

    % A fourth pass, for a `Json` value holding a non-finite float ([LGRA.5.8.10]),
    % comes after the limits: `ds.json.holds_non_finite` recurses, so it walks only
    % a term the limits have bounded.
slot_fault(Schema, Values, Index, Reason) :-
    Commons = slot_commons(Schema),
    ( if first_slot_fault(Commons, Values, 0, Index0, Reason0) then
        Index = Index0,
        Reason = Reason0
    else if first_nan(Commons, Values, 0, Index1) then
        Index = Index1,
        Reason = sr_nan_rejected
    else if first_json_limit(Commons, Values, 0, Index2, Breach) then
        Index = Index2,
        Reason = sr_json_limit(Breach)
    else
        first_json_non_finite(Commons, Values, 0, Index),
        Reason = sr_json_nonfinite
    ).

:- pred first_json_non_finite(list(slot_common)::in, list(ds_value)::in,
                              int::in, int::out) is semidet.

first_json_non_finite([_ | Cs], [V | Vs], I, Index) :-
    ( if V = json(J), holds_non_finite(J) then
        Index = I
    else
        first_json_non_finite(Cs, Vs, I + 1, Index)
    ).

:- pred first_json_limit(list(slot_common)::in, list(ds_value)::in, int::in,
                         int::out, json_breach::out) is semidet.

first_json_limit([_ | Cs], [V | Vs], I, Index, Breach) :-
    ( if V = json(J), limit_breach(J) = yes(B) then
        Index = I,
        Breach = B
    else
        first_json_limit(Cs, Vs, I + 1, Index, Breach)
    ).

:- pred first_nan(list(slot_common)::in, list(ds_value)::in, int::in,
                  int::out) is semidet.

first_nan([_ | Cs], [V | Vs], I, Index) :-
    ( if V = float(F), float.is_nan(F) then
        Index = I
    else
        first_nan(Cs, Vs, I + 1, Index)
    ).

:- pred first_slot_fault(list(slot_common)::in, list(ds_value)::in, int::in,
                         int::out, slot_reason::out) is semidet.

first_slot_fault([C | Cs], [V | Vs], I, Index, Reason) :-
    ( if inadmissible(C, V, R) then
        Index = I,
        Reason = R
    else
        first_slot_fault(Cs, Vs, I + 1, Index, Reason)
    ).

slot_ref_fault(Wrong, Schema, Values, Index) :-
    first_slot_ref_fault(Wrong, slot_commons(Schema), Values, 0, Index).

:- pred first_slot_ref_fault(
    pred(schema_name, fact_id)::in(pred(in, in) is semidet),
    list(slot_common)::in, list(ds_value)::in, int::in, int::out) is semidet.

first_slot_ref_fault(Wrong, [C | Cs], [V | Vs], I, Index) :-
    not inadmissible(C, V, _),
    ( if
        C ^ sc_kind = k_schema(Declared),
        V = fact_ref(Id),
        Wrong(Declared, Id)
    then
        Index = I
    else
        first_slot_ref_fault(Wrong, Cs, Vs, I + 1, Index)
    ).

:- pred inadmissible(slot_common::in, ds_value::in, slot_reason::out)
    is semidet.

    % A root-null `Json` in a `Json` slot is the canonical `null` ([LNUL.3.4]).
    %
inadmissible(Common, V, Reason) :-
    ( if
        ( V = null
        ; Common ^ sc_kind = k_json, V = json(j_null)
        )
    then
        Common ^ sc_nullable = non_null,
        Reason = sr_null_non_nullable
    else
        not admits_kind(Common ^ sc_kind, V),
        Reason = sr_kind_mismatch
    ).

    % A `duration` or `ratio` value matches no arm and is refused. A `time` has
    % already become its `int` of `utc_ns` (`ds.value.stored_value`).
    %
:- pred admits_kind(slot_kind::in, ds_value::in) is semidet.

admits_kind(k_int, int(_)).
admits_kind(k_float, float(_)).
admits_kind(k_string, str(_)).
admits_kind(k_bool, bool(_)).
admits_kind(k_json, json(_)).
admits_kind(k_bytes, bytes(_)).
admits_kind(k_schema(_), fact_ref(_)).
admits_kind(k_time, int(_)).
admits_kind(k_date, int(_)).
admits_kind(k_duration, int(_)).

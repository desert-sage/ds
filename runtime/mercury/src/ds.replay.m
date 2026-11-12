% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.replay -- driving a decoded recording back through a fresh engine.
%
% Four event kinds are inputs: a host's `FactAssert` (never a `FactEmit`,
% [RFCS.6a.1]), a host retract, a clock sample, and a pump boundary ([RFCS.22]),
% where replay pumps and nowhere else. Everything else is re-derived.
%
% Every compare-class atom is compared by its bytes ([LFST.9.6], [LFST.9.3.1]): a
% recorder on the replaying engine (`ds.rfcs.capture_step`) writes the atoms the
% replay re-derives onto a queue, each recorded one is compared against its head
% where the file holds it, and one left over at the end diverges. Bytes, since a
% `fire_id`'s intern half is table-local. A `timetag` is compared by pairing
% ([RFCS.11.2], [LFST.9.3.6]).
%-----------------------------------------------------------------------------%

:- module ds.replay.
:- interface.

:- import_module ds.dsc.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.rfcs.
:- import_module list.
:- import_module uint64.

    % What delivering one recorded event did. Every constructor after `pumped` is the
    % last step.
    %
:- type replay_step
    --->    delivered(list(effect))
    ;       pumped(list(effect))
            % A recorded pump ran ([RFCS.22]).
    ;       unknown_schema(uint64)
            % The host `FactAssert` with this `seq` names a schema the engine
            % does not hold ([RFCS.5.4]).
    ;       unknown_fact_id(uint64)
            % The host `FactRetract` with this `seq` names a `fact_id` no earlier
            % atom left in working memory ([RFCS.7.3]).
    ;       recording_incomplete(uint64)
            % The recording's first event has this `seq`, not 0 ([LTIM.2.8.5],
            % [LFST.5.3]). Nothing was delivered.
    ;       binding_refused(int, string)
            % The recording's dialect-binding tuple is not the program's
            % ([RBND.5.1], [RBND.2.1]): -700, -701 or -703, with `ds.binding`'s
            % detail. Nothing was delivered.
    ;       diverged(uint64)
            % The replay parted from the recording at this `seq`:
            %   - the `ExternalAssert` with this `seq` did not reproduce
            %     (RFCS.24.2): its delivery was refused, or asserted other facts
            %     than its `fact_ids`;
            %   - the compare-class atom with this `seq` is not the next one the
            %     replay re-derived ([LFST.9.3.1]);
            %   - one past the last `seq`: the replay re-derived an atom the
            %     recording does not hold;
            %   - a `CacheSeed`, at the `seq` of the last event before it, 0 for
            %     none ([RFCS.26.2]): refused, or after an event atom.
    ;       input_refused(uint64, int, string).
            % [RFCS.6.7]: the input with this `seq` was refused for a reason that
            % is not an outcome of the recorded run. A bound's refusal, a halt
            % the input itself raised and a pump's status are outcomes, all but
            % a pump refused before its step (`rfcs_6_7_pump_refused`).

    % Events that are not inputs produce no step.
    %
:- pred replay_stream(program::in, decoded_stream::in, list(replay_step)::out,
                      engine::in, engine::out) is det.

    % Replay what a reader read of a recording it stopped at an unannounced
    % `FactAssert` ([RFCS.5.4]), whose `seq` is given: every event before it, then
    % the atom refused as `unknown_schema`, unless a refusal came first.
    %
:- pred replay_unannounced(program::in, decoded_stream::in, uint64::in,
                           list(replay_step)::out, engine::in, engine::out)
    is det.

    % The `DS_ERR_*` code for a step that refuses; fails for one that delivered.
    %
:- func replay_refusal_code(replay_step) = int is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.binding.
:- import_module ds.chrono.
:- import_module string.
:- import_module ds.fact.
:- import_module ds.fact_receive.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.schema.
:- import_module ds.value.
:- import_module ds.wm.
:- import_module bitmap.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module set.
:- import_module uint32.
:- import_module uint8.

%-----------------------------------------------------------------------------%

replay_stream(P, DS, Steps, !E) :-
    replay_to(P, DS, no, Steps, !E).

replay_unannounced(P, DS, Seq, Steps, !E) :-
    replay_to(P, DS, yes(Seq), Steps, !E).

    % `Stop` is the `seq` of the unannounced FactAssert the reader stopped at.
    %
:- pred replay_to(program::in, decoded_stream::in, maybe(uint64)::in,
                  list(replay_step)::out, engine::in, engine::out) is det.

replay_to(P, DS, Stop, Steps, !E) :-
    First = DS ^ dsm_first_seq,
    ( if rbnd_5_1_refusal(DS ^ dsm_meta, header(P), Refusal) then
        Steps = [Refusal]
    else if First = yes(S), S \= 0u64 then
        Steps = [recording_incomplete(S)]
    else
        list.filter(seed_is_late, DS ^ dsm_seeds, Late, Prelude),
        rfcs_26_2_apply(Prelude, Refused, !E),
        (
            Refused = yes(Sd),
            Steps = [diverged(Sd ^ rsd_seq)]
        ;
            Refused = no,
            V0 = verify(capture_init(engine_now(!.E)), [], map.init, map.init),
            replay_all(P, DS, 0, 0, set.init, DS ^ dsm_events,
                DS ^ dsm_external, DS ^ dsm_compare, Late, V0, V, [],
                RevSteps0, !E),
            % An atom left over is one the recording does not hold; a replay that
            % stopped at a refusal never reaches this.
            ( if
                Stop = yes(StopSeq),
                not (
                    RevSteps0 = [Prior | _],
                    replay_refusal_code(Prior) = _
                )
            then
                RevSteps = [unknown_schema(StopSeq) | RevSteps0]
            else if
                Stop = no,
                RevSteps0 = [Last | _],
                not replay_refusal_code(Last) = _,
                V ^ vf_pending = [_ | _]
            then
                RevSteps = [diverged(past_last_seq(DS)) | RevSteps0]
            else
                RevSteps = RevSteps0
            ),
            Steps = list.reverse(RevSteps)
        )
    ).

:- pred seed_is_late(recorded_seed::in) is semidet.

seed_is_late(Sd) :-
    Sd ^ rsd_late = yes.

    % The recording's seeds, in stream order, before the first stream event, each
    % with its recorded deadline. Answers the first the engine refused.
    %
    %@spec [RFCS.26.2]
:- pred rfcs_26_2_apply(list(recorded_seed)::in, maybe(recorded_seed)::out,
                        engine::in, engine::out) is det.

rfcs_26_2_apply([], no, !E).
rfcs_26_2_apply([Sd | Sds], Refused, !E) :-
    Sd ^ rsd_seed = cache_seed(Key, Text, Deadline),
    replay_seed_cache(Key, Text, Deadline, Result, !E),
    ( if Result = seeded then
        rfcs_26_2_apply(Sds, Refused, !E)
    else
        Refused = yes(Sd)
    ).

replay_refusal_code(unknown_schema(_)) = -101.
replay_refusal_code(unknown_fact_id(_)) = -730.
replay_refusal_code(recording_incomplete(_)) = -729.
replay_refusal_code(binding_refused(Code, _)) = Code.
replay_refusal_code(diverged(_)) = -725.
replay_refusal_code(input_refused(_, Code, _)) = Code.

:- func past_last_seq(decoded_stream) = uint64.

past_last_seq(DS) = list.foldl(past, Seqs, 0u64) :-
    Seqs = list.map((func({S, _}) = seq_value(S)), DS ^ dsm_events)
        ++ list.map((func(C) = C ^ rcm_seq), DS ^ dsm_compare).

:- func past(uint64, uint64) = uint64.

past(Seq, Max) = ( if Seq + 1u64 > Max then Seq + 1u64 else Max ).

:- type verify
    --->    verify(
                vf_capture :: capture,
                vf_pending :: list(compare_atom),
                            % written and not yet matched, oldest first
                vf_fwd     :: map(uint64, uint64),
                            % a recorded timetag -> the re-derived one
                vf_back    :: map(uint64, uint64)
                            % a re-derived timetag -> the recorded one
            ).

    % `First` is the engine's event count before the step, `E` the engine after it.
    %
:- pred capture(uint64::in, list(effect)::in, engine::in,
                verify::in, verify::out) is det.

capture(First, Effects, E, !V) :-
    capture_step(session_header(E),
        rfcs_ctx(engine_schemas(E), engine_interns(E)), First, Effects, Atoms,
        !.V ^ vf_capture, C),
    !V ^ vf_capture := C,
    !V ^ vf_pending := !.V ^ vf_pending ++ Atoms.

    % The recorded compare-class atom against the next one the replay re-derived.
    %
    %@spec [LFST.9.3.1]
:- pred lfst_9_3_1_match(recorded_compare::in, bool::out,
                         verify::in, verify::out,
                         list(replay_step)::in, list(replay_step)::out) is det.

lfst_9_3_1_match(C, Diverged, !V, !Steps) :-
    ( if
        !.V ^ vf_pending = [Head | Rest],
        lfst_9_3_6_same(C ^ rcm_atom, Head, !.V, V1)
    then
        !:V = V1 ^ vf_pending := Rest,
        Diverged = no
    else
        Diverged = yes,
        !:Steps = [diverged(C ^ rcm_seq) | !.Steps]
    ).

    % A `timetag` is an identity, not a value ([RFCS.11.2]): [LDET.5.5] fixes the
    % order timetags ascend in, not their origin or step.
    %
    %@spec [LFST.9.3.6]
:- pred lfst_9_3_6_same(compare_atom::in, compare_atom::in,
                        verify::in, verify::out) is semidet.

lfst_9_3_6_same(Recorded, Rederived, !V) :-
    Recorded ^ ca_atom = Rederived ^ ca_atom,
    ( if split_timetag(Recorded, KeptR, TR) then
        split_timetag(Rederived, KeptD, TD),
        KeptR = KeptD,
        lfst_9_3_6_pair(TR, TD, !V)
    else
        Recorded = Rederived
    ).

    % Each recorded timetag is paired with the re-derived one the first time either
    % occurs, and every later atom must agree, both ways. An absent timetag (0) is
    % not paired: both sides must be absent together.
    %
    %@spec [LFST.9.3.6]
:- pred lfst_9_3_6_pair(uint64::in, uint64::in, verify::in, verify::out)
    is semidet.

lfst_9_3_6_pair(Recorded, Rederived, !V) :-
    ( if ( Recorded = 0u64 ; Rederived = 0u64 ) then
        Recorded = Rederived
    else if map.search(!.V ^ vf_fwd, Recorded, Paired) then
        Paired = Rederived
    else
        not map.contains(!.V ^ vf_back, Rederived),
        !V ^ vf_fwd := map.det_insert(!.V ^ vf_fwd, Recorded, Rederived),
        !V ^ vf_back := map.det_insert(!.V ^ vf_back, Rederived, Recorded)
    ).

    % The recording's whole dialect-binding tuple against the program's, before
    % anything is delivered, recorded first ([RBND.6.1]):
    %   - one of `dsc_sha256` and `dialect_def_sha256` and not the other: -703
    %     ([RBND.2.1]);
    %   - neither: replayed without a binding check;
    %   - both: the comparator's answer, -700 or -701 with its detail ([RBND.5.2]).
    %
    % No arm for an engine with no DSC ([RBND.5.4]): every program here has one.
    %
:- pred rbnd_5_1_refusal(stream_meta::in, dsc_header::in, replay_step::out)
    is semidet.

rbnd_5_1_refusal(Meta, H, Refusal) :-
    HasHash = ( if list.length(Meta ^ sm_dsc_hash) = 32 then yes else no ),
    HasDef = ( if list.length(Meta ^ sm_def_sha) = 32 then yes else no ),
    ( if HasHash = yes, HasDef = no then
        Refusal = binding_refused(-703, "the recording carries a dsc_hash "
            ++ "and no 32-byte dialect_def_sha256 (RBND.2.1)")
    else if HasHash = no, HasDef = yes then
        Refusal = binding_refused(-703, "the recording carries a "
            ++ "dialect_def_sha256 and no 32-byte dsc_hash (RBND.2.1)")
    else
        % Both or neither; neither has nothing to compare.
        HasHash = yes,
        list.length(H ^ dh_sha256) = 32,
        compare_dialect(
            dialect_binding(Meta ^ sm_dsc_hash, Meta ^ sm_capabilities,
                Meta ^ sm_def_sha),
            dialect_binding(H ^ dh_sha256, H ^ dh_capabilities,
                H ^ dh_dialect_sha))
            = mismatch(Code, Detail),
        Refusal = binding_refused(Code, Detail)
    ).

    % The events, `ExternalAssert`s and compare-class atoms, in the file's order. `N`
    % events and `K` ExternalAsserts have been delivered; the `re_after`,
    % `rcm_events` and `rcm_external` counts place the others among them.
    %
    % `Known`: the recorded fact ids a `FactRetract` may name ([RFCS.7.3]). An id
    % joins from a `FactAssert` that put a fact in working memory, a `FactEmit` whose
    % fact is still there when its atom is read, and an `ExternalAssert` that
    % reproduced; a `FactRetract` takes its id out.
    %
    % `Late`: `CacheSeed`s after an event atom ([RFCS.26.2]), which no recorder
    % writes. The replay parts from the recording at the first.
    %
:- pred replay_all(program::in, decoded_stream::in, int::in, int::in,
                   set(fact_id)::in,
                   list({seq, stream_event})::in, list(recorded_external)::in,
                   list(recorded_compare)::in, list(recorded_seed)::in,
                   verify::in, verify::out,
                   list(replay_step)::in, list(replay_step)::out,
                   engine::in, engine::out) is det.

replay_all(P, DS, N, K, Known, Events, Externals, Compares, Late, !V, !Steps,
        !E) :-
    ( if
        Compares = [C | Cs],
        C ^ rcm_events =< N,
        C ^ rcm_external =< K
    then
        lfst_9_3_1_match(C, Diverged, !V, !Steps),
        (
            Diverged = yes
        ;
            Diverged = no,
            replay_all(P, DS, N, K, Known, Events, Externals, Cs, Late, !V,
                !Steps, !E)
        )
    else if
        Late = [Sd | _],
        Sd ^ rsd_events =< N,
        Sd ^ rsd_external =< K
    then
        !:Steps = [diverged(Sd ^ rsd_seq) | !.Steps]
    else if
        Externals = [X | Xs],
        X ^ re_after =< N
    then
        replay_external(X, Diverged, Known, Known1, !V, !Steps, !E),
        (
            Diverged = yes
        ;
            Diverged = no,
            replay_all(P, DS, N, K + 1, Known1, Events, Xs, Compares, Late,
                !V, !Steps, !E)
        )
    else
        (
            Events = [Ev | Evs],
            replay_event(P, DS, Ev, Stop, Known, Known1, !V, !Steps, !E),
            (
                Stop = yes
            ;
                Stop = no,
                replay_all(P, DS, N + 1, K, Known1, Evs, Externals, Compares,
                    Late, !V, !Steps, !E)
            )
        ;
            Events = []
        )
    ).

    % RFCS.24.2: delivered as RFCS.23.7 receives a FactExternal, `ttl_ns` on the
    % received fact. Handles replay as recorded, so each fact asserted must be the
    % one `fact_ids` names. A delivery an assert's own halt stopped part-way is an
    % outcome ([RFCS.6.7]); one that met an engine already halted diverges.
    %
:- pred replay_external(recorded_external::in, bool::out,
                        set(fact_id)::in, set(fact_id)::out,
                        verify::in, verify::out,
                        list(replay_step)::in, list(replay_step)::out,
                        engine::in, engine::out) is det.

replay_external(X, Diverged, !Known, !V, !Steps, !E) :-
    Ttl = X ^ re_ttl_ns,
    ( if Ttl = 0u64 then Window = no else Window = yes(duration_from_ns(Ttl)) ),
    First = engine_event_count(!.E),
    assert_external_with(bitmap_of(X ^ re_fact), Window, Result, Ids,
        Effects, !E),
    capture(First, Effects, !.E, !V),
    ( if
        ( Result = ext_asserted
        ; Result = ext_stopped(refused_halted(_))
        ),
        list.map(fact_id_value, Ids) = X ^ re_fact_ids
    then
        Diverged = no,
        set.insert_list(Ids, !Known),
        !:Steps = [delivered(Effects) | !.Steps]
    else
        Diverged = yes,
        !:Steps = [diverged(seq_value(X ^ re_seq)), delivered(Effects)
            | !.Steps]
    ).

:- func bitmap_of(list(uint8)) = bitmap.

bitmap_of(Bytes) = BM :-
    fill(0, Bytes, bitmap.init(list.length(Bytes) * 8), BM).

:- pred fill(int::in, list(uint8)::in, bitmap::bitmap_di, bitmap::bitmap_uo)
    is det.

fill(_, [], !BM).
fill(I, [B | Bs], !BM) :-
    bitmap.set_uint8(I, B, !BM),
    fill(I + 1, Bs, !BM).

    % `Stop` is `yes` when the event was refused.
    %
:- pred replay_event(program::in, decoded_stream::in, {seq, stream_event}::in,
                     bool::out, set(fact_id)::in, set(fact_id)::out,
                     verify::in, verify::out,
                     list(replay_step)::in, list(replay_step)::out,
                     engine::in, engine::out) is det.

replay_event(_P, DS, {Seq, Event}, Stop, !Known, !V, !Steps, !E) :-
    First = engine_event_count(!.E),
    (
        Event = se_fact_assert(Id, SchemaId, Values, Window),
        ( if set.member(seq_value(Seq), DS ^ dsm_emitted) then
            % Derived: a `FactEmit` ([RFCS.6a.1], [LERR.9.8]). Its id is known if
            % the fact the replay re-derived is still in working memory.
            Stop = no,
            ( if lookup_fact(engine_wm(!.E), Id, _) then
                set.insert(Id, !Known)
            else
                true
            )
        else if
            schema_name_at(DS, SchemaId, Name),
            find_schema(engine_schemas(!.E), engine_interns(!.E), Name, Schema)
        then
            % The values arrived against the reader's intern table.
            list.map_foldl(reintern(DS), Values, Rebound, !E),
            % The recorded `ttl_ns` is a window from the assert's own sample
            % ([RFCS.6.2]).
            (
                Window = yes(W),
                host_assert_with_ttl(Schema, Rebound, W, Result, Effects, !E)
            ;
                Window = no,
                host_assert(Schema, Rebound, no, Result, Effects, !E)
            ),
            ( if known_after(Result) = yes then
                set.insert(Id, !Known)
            else
                true
            ),
            capture(First, Effects, !.E, !V),
            !:Steps = [delivered(Effects) | !.Steps],
            ( if rfcs_6_7_refused(Result, Code, Detail) then
                !:Steps = [input_refused(seq_value(Seq), Code, Detail)
                    | !.Steps],
                Stop = yes
            else
                Stop = no
            )
        else
            !:Steps = [unknown_schema(seq_value(Seq)) | !.Steps],
            Stop = yes
        )
    ;
        Event = se_fact_retract(Id),
        ( if engine_halted(!.E) = yes(_) then
            !:Steps = [met_halted(Seq) | !.Steps],
            Stop = yes
        else if set.remove(Id, !Known) then
            host_retract(Id, Effects, !E),
            capture(First, Effects, !.E, !V),
            !:Steps = [delivered(Effects) | !.Steps],
            Stop = no
        else
            !:Steps = [unknown_fact_id(seq_value(Seq)) | !.Steps],
            Stop = yes
        )
    ;
        Event = se_pump_boundary,
        % [RFCS.22].
        ( if engine_halted(!.E) = yes(_) then
            !:Steps = [met_halted(Seq) | !.Steps],
            Stop = yes
        else
            pump(default_budget, PumpEffects, !E),
            capture(First, PumpEffects, !.E, !V),
            !:Steps = [pumped(PumpEffects) | !.Steps],
            ( if
                first_pump_status(PumpEffects) = yes(Status),
                rfcs_6_7_pump_refused(Status, Code, Detail)
            then
                !:Steps = [input_refused(seq_value(Seq), Code, Detail)
                    | !.Steps],
                Stop = yes
            else
                Stop = no
            )
        )
    ;
        Event = se_clock_tick(To, Wall),
        % [RFCS.10.5]: both clocks, the wall clock unset when there is no `has_wall`
        % ([RFCS.10.1]). Setting is not a sample ([NTST.3.3]): the next input or
        % `PumpBoundary` takes it ([LTIM.2.8.5]). A `clock_ns` outside the clock's
        % range ends the replay, as a host's move past it is refused.
        ( if ntst_3_1_set_past_range(To) then
            !:Steps = [input_refused(seq_value(Seq), -205,
                "a ClockAdvance outside the monotonic clock's range")
                | !.Steps],
            Stop = yes
        else
            engine_use_mock_clock(!E),
            set_clock(To, _, !E),
            (
                Wall = yes(W),
                set_wall_clock(W, !E)
            ;
                Wall = no,
                unset_wall_clock(!E)
            ),
            Stop = no
        )
    ;
        ( Event = se_call_response(_, _) ; Event = se_call_error(_, _)
        ; Event = se_rule_lhs_facts(_, _) ; Event = se_fire_begin(_)
        ; Event = se_fire_end(_) ; Event = se_timer_armed(_, _, _)
        ; Event = se_call_issued(_, _, _, _, _)
        ; Event = se_clock_advance(_) ; Event = se_engine_error(_, _)
        ; Event = se_cache_set(_, _, _) ; Event = se_cache_delete(_)
        ; Event = se_emit(_, _)
        ; Event = se_publish(_, _, _) ; Event = se_fact_withdraw(_, _)
        ; Event = se_fact_withdraw_unnamed(_, _)
        ; Event = se_log_emitted(_, _) ),
        % Re-derived, never delivered.
        Stop = no
    ).

:- func met_halted(seq) = replay_step.

met_halted(Seq) = input_refused(seq_value(Seq), -10,
    "the input met an engine already halted").

    % [RFCS.6.7]: a replayed assert's status, where it ends the replay. A bound's
    % refusal goes on, to compare the `BoundsError`. `refused_halted` is always an
    % engine halted before the assert: its own halt reports the fact as entered.
    %
:- pred rfcs_6_7_refused(assert_result::in, int::out, string::out) is semidet.

rfcs_6_7_refused(Result, Code, Detail) :-
    (
        ( Result = inserted(_)
        ; Result = noop(_)
        ; Result = replaced(_, _)
        ; Result = rejected(_)
        ),
        fail
    ;
        Result = invalid(_, Reason),
        (
            ( Reason = sr_kind_mismatch
            ; Reason = sr_null_non_nullable
            ),
            Code = -104
        ;
            Reason = sr_nan_rejected,
            Code = -216
        ;
            Reason = sr_json_nonfinite,
            Code = -217
        ;
            Reason = sr_json_limit(_),
            Code = -221
        ),
        Detail = "a slot does not admit the recorded value"
    ;
        Result = refused_halted(_),
        Code = -10,
        Detail = "the input met an engine already halted"
    ;
        Result = refused_arity(_, _),
        Code = -1,
        Detail = "the recorded values are not one per slot"
    ;
        Result = refused_unregistered(_),
        Code = -101,
        Detail = "a schema the engine does not hold"
    ;
        Result = refused_time_range(_),
        Code = -205,
        Detail = "a Date outside its range"
    ;
        Result = refused_encoding(_),
        Code = -222,
        Detail = "text that is not well-formed UTF-8"
    ;
        Result = refused_tz_row(_),
        Code = -1,
        Detail = "a malformed TimeZoneOffset row"
    ;
        Result = refused_ttl_range,
        Code = -205,
        Detail = "a deadline outside the Time range"
    ).

    % [RFCS.6.7]: a replayed pump's status, where it ends the replay. A refused
    % rule write and a refused call are outcomes of the recorded run. A pump
    % refused before its step ([NLFC.9.5]) left no `PumpBoundary` in the run, so
    % a replay meets one only on an engine that is not the run's: one the host
    % seeded, which [RFCS.26.2] forbids.
    %
    %@spec [RFCS.6.7]
:- pred rfcs_6_7_pump_refused(pump_status::in, int::out, string::out)
    is semidet.

rfcs_6_7_pump_refused(Status, Code, Detail) :-
    (
        ( Status = ps_nan_rejected
        ; Status = ps_contract_breach(_)
        ),
        fail
    ;
        Status = ps_time_range,
        Code = -205,
        Detail = "the pump's first sample would give a held seed a deadline "
            ++ "outside the Time range"
    ).

    % Whether a replayed host assert leaves a fact in working memory under the
    % recorded id, so a later `FactRetract` may name it.
    %
:- func known_after(assert_result) = bool.

known_after(inserted(_)) = yes.
known_after(noop(_)) = yes.
known_after(replaced(_, _)) = yes.
known_after(rejected(_)) = no.
known_after(invalid(_, _)) = no.
known_after(refused_halted(_)) = no.
known_after(refused_arity(_, _)) = no.
known_after(refused_unregistered(_)) = no.
known_after(refused_time_range(_)) = no.
known_after(refused_encoding(_)) = no.
known_after(refused_tz_row(_)) = no.
known_after(refused_ttl_range) = no.

:- pred reintern(decoded_stream::in, ds_value::in, ds_value::out,
                 engine::in, engine::out) is det.

reintern(DS, V0, V, !E) :-
    ( if V0 = str(Ref), expand(DS ^ dsm_interns, Ref, Text) then
        engine_intern(Text, NewRef, !E),
        V = str(NewRef)
    else
        V = V0
    ).

:- pred schema_name_at(decoded_stream::in, schema_id::in, string::out)
    is semidet.

schema_name_at(DS, Id, Name) :-
    % The synthetic id counts from 1, in `SchemaDef` arrival order.
    list.index0(DS ^ dsm_schemas,
        uint32.cast_to_int(schema_id_value(Id)) - 1, Name).

:- pred find_schema(list(schema)::in, intern_table::in, string::in,
                    schema::out) is semidet.

find_schema([S | Ss], IT, Name, Found) :-
    ( if expand(IT, schema_name_ref(S ^ s_name), Name) then
        Found = S
    else
        find_schema(Ss, IT, Name, Found)
    ).

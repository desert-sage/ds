% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.wm -- working memory: a pure value, threaded `in`/`out`.
%-----------------------------------------------------------------------------%

:- module ds.wm.
:- interface.

:- import_module ds.chrono.
:- import_module ds.fact.
:- import_module ds.id.
:- import_module ds.schema.
:- import_module ds.value.
:- import_module array.
:- import_module int32.
:- import_module int64.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%

:- type wm.

:- func init_wm = wm.

    % Working memory for a program whose compiler-synthesised schemas
    % (`ds.schema.synthetic`) have these ids. Their facts take ids from a range
    % of their own, so an author fact's id counts author facts only.
    %
:- func init_wm_for(list(schema_id)) = wm.

    % The same, for a program whose `TimeZoneOffset` ([LTIM.10.6]) has this id.
    % With `no`, a hand-built network, no fact is indexed by zone.
    %
:- func init_wm_for(list(schema_id), maybe(schema_id)) = wm.

%-----------------------------------------------------------------------------%
% Assertion
%-----------------------------------------------------------------------------%

:- pred assert_fact(schema::in, list(ds_value)::in, instant::in,
                    maybe(instant)::in, tms_linkage::in, hydration_tag::in,
                    assert_result::out, wm::in, wm::out) is det.

    % A slot array as `assert_fact` stores it before judging it ([LNUL.3.4],
    % [NFCT.2.3]), so a `publish`, which stores nothing, judges what an `emit`
    % of the same values would ([LTIE.4.8]).
    %
:- func stored_slots(schema, list(ds_value)) = list(ds_value).

    % The no-op reassertion's comparison [LFAC.2.5.1], and [RFCS.23.7]'s "equal":
    % every slot of the second array unchanged from the first under its
    % tolerance.
    %
:- pred unchanged(schema::in, array(ds_value)::in, array(ds_value)::in)
    is semidet.

%-----------------------------------------------------------------------------%
% Retraction
%-----------------------------------------------------------------------------%

    % Fails on a fact that is not live: that is the caller's error, not a no-op.
    % The cause is unused here; the caller's event records it.
    %
:- pred retract_fact(fact_id::in, retract_cause::in, wm::in, wm::out)
    is semidet.

    % Every fact whose deadline is at or before the given instant, removed, in
    % ascending deadline order, ties in arm order.
    %
:- pred expire(instant::in, list(fact)::out, wm::in, wm::out) is det.

    % The earliest armed deadline, if any.
    %
:- pred next_expiry(wm::in, instant::out) is semidet.

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

:- pred lookup_fact(wm::in, fact_id::in, fact::out) is semidet.

    % Stamp a live fact with its FactExternal identity, once: a fact already
    % stamped keeps its stamp, so a no-op reassert's later FactAssert leaves the
    % fact's `event_id` alone ([LFST.5.6]). A fact no longer live is left alone.
    %
:- pred stamp_fact(fact_id::in, fact_stamp::in, wm::in, wm::out) is det.

    % Every live fact of a schema, in insertion order.
    %
:- func facts_of_schema(wm, schema_id) = list(fact).

:- func live_count(wm) = int.

    % The live facts that count against working-memory capacity: all but those
    % of the given schemas.
    %
:- func lerr_9_10_capacity_count(wm, list(schema_id)) = int.

:- pred fact_for_identity(wm::in, fact_identity::in, fact::out) is semidet.

    % [LTIM.10.7]: the offset, in seconds east, of `Zone` at `Utc` (UTC ns).
    % "UTC" itself is the caller's ([LTIM.10.8]).
    %
    % Keyed on the zone's interned ref, one ref to a string, so a zone that was
    % never interned has no answer; the caller looks it up
    % (`ds.intern.interned`).
    %
:- pred ltim_10_7_offset(wm::in, intern_ref::in, int64::in, int32::out)
    is semidet.

    % How many zones have a live fact. For tests.
    %
:- func tz_zone_count(wm) = int.

    % Whether this is the program's `TimeZoneOffset` (`init_wm_for/2`).
    %
:- pred is_tz_schema(wm::in, schema_id::in) is semidet.

    % The facts an identity upsert superseded since the last call, oldest
    % first, and working memory with the list emptied. Each still owes its
    % series sample [LSER.8.5.1], and a walk of working memory cannot see it.
    % A retract and a TTL expiry park nothing.
    %
:- pred take_superseded(list(fact)::out, wm::in, wm::out) is det.

    % The facts of a schema whose series samples the next sweep will absorb
    % ([LSER.13.14]'s samples not yet absorbed): those parked by a supersede
    % since the last `take_superseded`, oldest first, then the live ones
    % asserted since it, in insertion order. A fact asserted and then retracted
    % or expired before the sweep is in neither.
    %
:- func unabsorbed_of_schema(wm, schema_id) = list(fact).

    % The id the next fact of this schema would take, taken without a fact
    % entering: for a host assert a bound refused, whose `FactAssert` is still
    % recorded ([RFCS.6.7]).
    %
:- pred mint_unentered_id(schema::in, fact_id::out, wm::in, wm::out) is det.

%-----------------------------------------------------------------------------%
% An insertion-ordered set of fact ids
%-----------------------------------------------------------------------------%

    % Fact ids in the order they were added, with O(1) amortized removal
    % [LNLS.4.7].
    %
    % Removal is lazy: a removed id stays until a read skips it, by a liveness
    % test the caller supplies. That is sound because a fact id is never reused.
    % When the dead outnumber the live, the removal that tips it compacts.
    %
:- type fact_seq.

:- func empty_fact_seq = fact_seq.

    % An id is added at most once.
    %
:- func fact_seq_add(fact_id, fact_seq) = fact_seq.

    % One member has gone. `IsLive` must already answer false for it.
    %
:- func fact_seq_drop(pred(fact_id)::in(pred(in) is semidet), fact_seq::in)
    = (fact_seq::out) is det.

:- func fact_seq_members(pred(fact_id)::in(pred(in) is semidet),
    fact_seq::in) = (list(fact_id)::out) is det.

:- func fact_seq_count(fact_seq) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.fault.
:- import_module ds.json.
:- import_module int.
:- import_module map.
:- import_module pqueue.
:- import_module set.
:- import_module uint32.
:- import_module uint64.
:- import_module version_hash_table.

%-----------------------------------------------------------------------------%

:- type wm
    --->    wm(
                wm_facts     :: version_hash_table(fact_id, fact),
                            % Hashed for [LNLS.4.7]; never walked.

                wm_by_schema :: map(uint32, fact_seq),
                            % Live means "in `wm_facts`".

                wm_identity  :: version_hash_table(fact_identity, fact_id),
                            % Facts with an identity (`project_identity`).
                            % Hashed for [LNLS.4.7]; never walked.

                wm_ident_of  :: version_hash_table(fact_id, fact_identity),
                            % The reverse of `wm_identity`: working memory
                            % holds no schema to recompute a key from.

                wm_deadlines :: ttl_queue,
                wm_next_id   :: uint64,

                wm_superseded :: list(fact),
                            % Newest first.

                wm_absorb_mark :: uint64,
                            % `wm_next_id` when `take_superseded` last ran.

                wm_synth_schemas :: set(uint32),
                wm_next_synth    :: uint64,

                wm_tz_schema :: maybe(uint32),
                wm_tz        :: tz_index
            ).

    % [LTIM.10.7]: each zone's live facts by `valid_from`, and a reverse map so
    % `remove` finds a fact's entry without the schema.
    %
:- type tz_index
    --->    tz_index(
                tz_zones :: version_hash_table(intern_ref, map(int64, tz_row)),
                tz_of    :: version_hash_table(fact_id, {intern_ref, int64})
            ).

:- type tz_row
    --->    tz_row(
                tr_until  :: int64,
                tr_offset :: int64,
                tr_fact   :: fact_id
            ).

init_wm = init_wm_for([]).

init_wm_for(Synthetic) = init_wm_for(Synthetic, no).

init_wm_for(Synthetic, Tz) = wm(version_hash_table.init_default(fact_id_hash),
    map.init,
    version_hash_table.init_default(identity_hash),
    version_hash_table.init_default(fact_id_hash),
    init_ttl_queue, 1u64, [], 1u64,
    set.from_list(list.map(schema_id_value, Synthetic)),
    synthetic_id_base,
    maybe.map_maybe(schema_id_value, Tz),
    tz_index(version_hash_table.init_default(tz_zone_hash),
        version_hash_table.init_default(fact_id_hash))).

:- pred tz_zone_hash(intern_ref::in, int::out) is det.

tz_zone_hash(Ref, Hash) :-
    % Fibonacci hashing: refs are small consecutive integers.
    Hash = uint64.cast_to_int(
        (uint64.cast_from_int(uint32.cast_to_int(intern_ref_value(Ref)))
            * 11400714819323198485u64) >> 1).

    % 2^62: past any author id a run reaches, and clear of the sign bit.
    %
:- func synthetic_id_base = uint64.

synthetic_id_base = 4611686018427387904u64.

take_superseded(list.reverse(WM0 ^ wm_superseded), WM0,
    (WM0 ^ wm_superseded := []) ^ wm_absorb_mark := WM0 ^ wm_next_id).

unabsorbed_of_schema(WM, SchemaId) = Parked ++ Fresh :-
    Parked = list.filter((pred(F::in) is semidet :- F ^ f_schema = SchemaId),
        list.reverse(WM ^ wm_superseded)),
    Fresh = list.filter((pred(F::in) is semidet :-
            fact_id_value(F ^ f_id) >= WM ^ wm_absorb_mark),
        facts_of_schema(WM, SchemaId)).

%-----------------------------------------------------------------------------%
% Assertion
%-----------------------------------------------------------------------------%

assert_fact(Schema, Slots0, Now, Deadline, Tms, Hydration, Result, !WM) :-
    % Stored forms first, so the check sees what is stored. A host assert and a
    % rule's emit both come through here.
    Slots = stored_slots(Schema, Slots0),
    ( if slot_fault(Schema, Slots, Index, Reason) then
        Result = invalid(Index, Reason)
    else
        assert_admissible(Schema, Slots, Now, Deadline, Tms, Hydration, Result,
            !WM)
    ).

stored_slots(Schema, Slots0) =
    lnul_3_4_canonical(slot_commons(Schema), list.map(stored_value, Slots0)).

    % [LNUL.3.4]: a `Json` slot's root-null document becomes the canonical
    % `null`; and [NFCT.2.3]: a `Duration` slot's negative count becomes `0`.
    %
    %@spec [LNUL.3.4]
    %@spec [NFCT.2.3]
:- func lnul_3_4_canonical(list(slot_common), list(ds_value)) = list(ds_value).

lnul_3_4_canonical([], Vs) = Vs.
lnul_3_4_canonical([_ | _], []) = [].
lnul_3_4_canonical([C | Cs], [V | Vs]) = [Canonical | lnul_3_4_canonical(Cs, Vs)] :-
    ( if C ^ sc_kind = k_json, V = json(j_null) then
        Canonical = null
    else if C ^ sc_kind = k_duration, V = int(N), N < 0i64 then
        Canonical = int(0i64)
    else
        Canonical = V
    ).

:- pred assert_admissible(schema::in, list(ds_value)::in, instant::in,
                          maybe(instant)::in, tms_linkage::in, hydration_tag::in,
                          assert_result::out, wm::in, wm::out) is det.

assert_admissible(Schema, Slots, Now, Deadline, Tms, Hydration, Result, !WM) :-
    Array = array.from_list(Slots),
    Identity = project_identity(Schema, Array),
    (
        Identity = no,
        insert_new(Schema, Array, Now, Deadline, Tms, Hydration, NewId, !WM),
        Result = inserted(NewId)
    ;
        Identity = yes(Key),
        ( if
            version_hash_table.search(!.WM ^ wm_identity, Key, OldId),
            version_hash_table.search(!.WM ^ wm_facts, OldId, Old)
        then
            ( if unchanged(Schema, Old ^ f_slots, Array) then
                % [LFAC.2.5.1]: not re-timestamped, not re-armed.
                Result = noop(OldId)
            else
                % [LFAC.2.5.3]. The old fact goes first here; the order the pair
                % is recorded in is the caller's ([RFCS.6.7]).
                !WM ^ wm_superseded := [Old | !.WM ^ wm_superseded],
                remove(OldId, !WM),
                insert_new(Schema, Array, Now, Deadline, Tms, Hydration, NewId,
                    !WM),
                Result = replaced(OldId, NewId)
            )
        else
            insert_new(Schema, Array, Now, Deadline, Tms, Hydration, NewId,
                !WM),
            Result = inserted(NewId)
        )
    ).

unchanged(Schema, Old, New) :-
    array.size(Old, Width),
    array.size(New, Width),
    all_slots_unchanged(slot_tests(Schema), 0, Old, New).

:- type slot_test
    --->    compared(tolerance)
    ;       not_compared.       % `role_engine` [LFAC.9.1]

:- pred all_slots_unchanged(list(slot_test)::in, int::in,
                            array(ds_value)::in, array(ds_value)::in)
    is semidet.

all_slots_unchanged([], _, _, _).
all_slots_unchanged([T | Ts], I, Old, New) :-
    array.size(Old, Width),
    % A short array fails: running out of data is not equality.
    I < Width,
    (
        T = compared(Tolerance),
        slot_unchanged(Tolerance, array.lookup(Old, I), array.lookup(New, I))
    ;
        T = not_compared
    ),
    all_slots_unchanged(Ts, I + 1, Old, New).

    % A non-logical slot has no role, so a `ts` there is compared.
    %
:- func slot_tests(schema) = list(slot_test).

slot_tests(Schema) = Ts :-
    (
        Schema ^ s_lifecycle = lc_logical(Slots, _),
        Ts = list.map(logical_test, Slots)
    ;
        Schema ^ s_lifecycle = lc_ttl(Slots, _),
        Ts = list.map(plain_test, Slots)
    ;
        Schema ^ s_lifecycle = lc_explicit(Slots),
        Ts = list.map(plain_test, Slots)
    ;
        Schema ^ s_lifecycle = lc_activation(Slots),
        Ts = list.map(plain_test, Slots)
    ).

:- func logical_test(logical_slot) = slot_test.
:- func plain_test(plain_slot) = slot_test.

logical_test(S) =
    ( if S ^ ls_role = role_engine then
        not_compared
    else
        compared(S ^ ls_tolerance)
    ).
plain_test(_) = compared(exact).

%-----------------------------------------------------------------------------%

mint_unentered_id(Schema, Id, !WM) :-
    next_id_for(Schema, Id, !WM).

:- pred next_id_for(schema::in, fact_id::out, wm::in, wm::out) is det.

next_id_for(Schema, Id, !WM) :-
    SchemaKey = schema_id_value(Schema ^ s_id),
    ( if set.contains(!.WM ^ wm_synth_schemas, SchemaKey) then
        Id = make_fact_id(!.WM ^ wm_next_synth),
        !WM ^ wm_next_synth := !.WM ^ wm_next_synth + 1u64
    else
        Id = make_fact_id(!.WM ^ wm_next_id),
        !WM ^ wm_next_id := !.WM ^ wm_next_id + 1u64
    ).

:- pred insert_new(schema::in, array(ds_value)::in, instant::in,
                   maybe(instant)::in, tms_linkage::in, hydration_tag::in,
                   fact_id::out, wm::in, wm::out) is det.

insert_new(Schema, Array, Now, Deadline, Tms, Hydration, Id, !WM) :-
    SchemaKey = schema_id_value(Schema ^ s_id),
    next_id_for(Schema, Id, !WM),

    Fact = fact(Id, Schema ^ s_id, Array, Now, Deadline, Tms, Hydration, no),
    !WM ^ wm_facts := version_hash_table.set(!.WM ^ wm_facts, Id, Fact),

    Prior = ( if map.search(!.WM ^ wm_by_schema, SchemaKey, L) then L
              else empty_fact_seq ),
    !WM ^ wm_by_schema := map.set(!.WM ^ wm_by_schema, SchemaKey,
        fact_seq_add(Id, Prior)),

    ( if project_identity(Schema, Array) = yes(Key) then
        !WM ^ wm_identity :=
            version_hash_table.set(!.WM ^ wm_identity, Key, Id),
        !WM ^ wm_ident_of := version_hash_table.set(!.WM ^ wm_ident_of, Id, Key)
    else
        true
    ),
    % [LTIM.10.7]: a `TimeZoneOffset` fact's slots are zone, valid_from,
    % valid_until, offset_s.
    ( if
        !.WM ^ wm_tz_schema = yes(SchemaKey),
        array.size(Array, 4),
        array.lookup(Array, 0) = str(Zone),
        array.lookup(Array, 1) = int(From),
        array.lookup(Array, 2) = int(Until),
        array.lookup(Array, 3) = int(Offset)
    then
        Tz0 = !.WM ^ wm_tz,
        Rows0 = ( if version_hash_table.search(Tz0 ^ tz_zones, Zone, R0) then R0
                  else map.init ),
        Rows = map.set(Rows0, From, tz_row(Until, Offset, Id)),
        !WM ^ wm_tz := tz_index(
            version_hash_table.set(Tz0 ^ tz_zones, Zone, Rows),
            version_hash_table.set(Tz0 ^ tz_of, Id, {Zone, From}))
    else
        true
    ),
    (
        % Whatever the lifecycle.
        Deadline = yes(At),
        ttl_arm(At, SchemaKey, Id, !.WM ^ wm_deadlines, Armed),
        !WM ^ wm_deadlines := Armed
    ;
        Deadline = no
    ).

    % Remove a fact from every index. The deadline stays armed: its entry goes
    % stale and is skipped when it falls due.
    %
:- pred remove(fact_id::in, wm::in, wm::out) is det.

remove(Id, !WM) :-
    ( if version_hash_table.search(!.WM ^ wm_facts, Id, Fact) then
        Facts = version_hash_table.delete(!.WM ^ wm_facts, Id),
        !WM ^ wm_facts := Facts,

        SchemaKey = schema_id_value(Fact ^ f_schema),
        ( if map.search(!.WM ^ wm_by_schema, SchemaKey, Seq) then
            IsLive = (pred(I::in) is semidet :-
                version_hash_table.search(Facts, I, _)),
            !WM ^ wm_by_schema := map.det_update(!.WM ^ wm_by_schema,
                SchemaKey, fact_seq_drop(IsLive, Seq))
        else
            true
        ),
        ( if version_hash_table.search(!.WM ^ wm_ident_of, Id, Key) then
            !WM ^ wm_ident_of :=
                version_hash_table.delete(!.WM ^ wm_ident_of, Id),
            ( if version_hash_table.search(!.WM ^ wm_identity, Key, Id) then
                !WM ^ wm_identity :=
                    version_hash_table.delete(!.WM ^ wm_identity, Key)
            else
                true
            )
        else
            true
        ),
        Tz0 = !.WM ^ wm_tz,
        ( if version_hash_table.search(Tz0 ^ tz_of, Id, {Zone, From}) then
            Of = version_hash_table.delete(Tz0 ^ tz_of, Id),
            ( if
                version_hash_table.search(Tz0 ^ tz_zones, Zone, Rows0),
                map.search(Rows0, From, Row),
                Row ^ tr_fact = Id
            then
                Rows = map.delete(Rows0, From),
                ( if map.is_empty(Rows) then
                    Zones = version_hash_table.delete(Tz0 ^ tz_zones, Zone)
                else
                    Zones = version_hash_table.set(Tz0 ^ tz_zones, Zone, Rows)
                )
            else
                Zones = Tz0 ^ tz_zones
            ),
            !WM ^ wm_tz := tz_index(Zones, Of)
        else
            true
        )
    else
        true
    ).

%-----------------------------------------------------------------------------%
% Retraction
%-----------------------------------------------------------------------------%

retract_fact(Id, _Cause, !WM) :-
    version_hash_table.search(!.WM ^ wm_facts, Id, _),
    remove(Id, !WM).

expire(Now, Expired, !WM) :-
    ttl_due(Now, Ids, !.WM ^ wm_deadlines, Remaining),
    !WM ^ wm_deadlines := Remaining,
    collect_and_remove(Ids, [], Expired, !WM).

:- pred collect_and_remove(list(fact_id)::in, list(fact)::in, list(fact)::out,
                           wm::in, wm::out) is det.

collect_and_remove([], Acc, list.reverse(Acc), !WM).
collect_and_remove([Id | Ids], Acc, Expired, !WM) :-
    ( if version_hash_table.search(!.WM ^ wm_facts, Id, Fact) then
        remove(Id, !WM),
        collect_and_remove(Ids, [Fact | Acc], Expired, !WM)
    else
        % A stale entry: the fact left before its deadline.
        collect_and_remove(Ids, Acc, Expired, !WM)
    ).

next_expiry(WM, At) :-
    ttl_earliest(WM ^ wm_deadlines, {At, _}, _).

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

lookup_fact(WM, Id, Fact) :-
    version_hash_table.search(WM ^ wm_facts, Id, Fact).

stamp_fact(Id, Stamp, !WM) :-
    ( if
        version_hash_table.search(!.WM ^ wm_facts, Id, Fact),
        Fact ^ f_stamp = no
    then
        !WM ^ wm_facts := version_hash_table.set(!.WM ^ wm_facts, Id,
            Fact ^ f_stamp := yes(Stamp))
    else
        true
    ).

facts_of_schema(WM, SchemaId) = Facts :-
    ( if map.search(WM ^ wm_by_schema, schema_id_value(SchemaId), Seq) then
        Facts = list.filter_map(resolve_fact(WM),
            fact_seq_members(is_live(WM), Seq))
    else
        Facts = []
    ).

:- pred is_live(wm::in, fact_id::in) is semidet.

is_live(WM, Id) :-
    version_hash_table.search(WM ^ wm_facts, Id, _).

:- func resolve_fact(wm, fact_id) = fact is semidet.

resolve_fact(WM, Id) = Fact :-
    lookup_fact(WM, Id, Fact).

live_count(WM) = version_hash_table.num_occupants(WM ^ wm_facts).

lerr_9_10_capacity_count(WM, Excluded) =
    live_count(WM) - list.foldl(
        ( func(S, N) = N + schema_count(WM, S) ),
        Excluded, 0).

:- func schema_count(wm, schema_id) = int.

schema_count(WM, SchemaId) =
    ( if map.search(WM ^ wm_by_schema, schema_id_value(SchemaId), Seq) then
        fact_seq_count(Seq)
      else
        0 ).

fact_for_identity(WM, Key, Fact) :-
    version_hash_table.search(WM ^ wm_identity, Key, Id),
    lookup_fact(WM, Id, Fact).

ltim_10_7_offset(WM, Zone, Utc, OffsetS) :-
    version_hash_table.search(WM ^ wm_tz ^ tz_zones, Zone, Rows),
    map.lower_bound_search(Rows, Utc, _From, Row),
    Utc < Row ^ tr_until,
    % [LTIM.10.9] bounds the offset to eighteen hours at the host's door.
    OffsetS = int32.cast_from_int(int64.cast_to_int(Row ^ tr_offset)).

tz_zone_count(WM) = version_hash_table.num_occupants(WM ^ wm_tz ^ tz_zones).

is_tz_schema(WM, Id) :-
    WM ^ wm_tz_schema = yes(schema_id_value(Id)).

%-----------------------------------------------------------------------------%
% fact_seq
%-----------------------------------------------------------------------------%

:- type fact_seq
    --->    fact_seq(
                fs_newest_first :: list(fact_id),
                            % Live and dead, newest first.
                fs_live         :: int,
                fs_dead         :: int
            ).

empty_fact_seq = fact_seq([], 0, 0).

fact_seq_add(Id, fact_seq(Ids, Live, Dead)) = fact_seq([Id | Ids], Live + 1, Dead).

fact_seq_drop(IsLive, fact_seq(Ids, Live0, Dead0)) = Seq :-
    Live = Live0 - 1,
    Dead = Dead0 + 1,
    ( if Dead > Live + fact_seq_slack then
        Seq = fact_seq(list.filter(IsLive, Ids), Live, 0)
    else
        Seq = fact_seq(Ids, Live, Dead)
    ).

    % Keeps a small sequence from compacting on every other removal.
    %
:- func fact_seq_slack = int.

fact_seq_slack = 8.

fact_seq_members(IsLive, fact_seq(Ids, _, _)) =
    list.reverse(list.filter(IsLive, Ids)).

fact_seq_count(Seq) = Seq ^ fs_live.

%-----------------------------------------------------------------------------%
% ttl_queue -- the facts' deadlines
%-----------------------------------------------------------------------------%

    % A FIFO per schema, and a heap for what a FIFO cannot take. A schema with
    % one `ttl` arms deadlines that never decrease, so its facts fall due in arm
    % order, at O(1) [LNLS.4.7]. A deadline earlier than its schema's last goes
    % to the heap [LDTL.1.2]. The next due entry is the least head of them all.
    %
:- type ttl_queue
    --->    ttl_queue(
                tq_fifos :: map(uint32, ttl_fifo),
                tq_heap  :: pqueue({instant, int}, fact_id),
                tq_next  :: int
                            % The arm counter: the tie-break, across FIFOs and
                            % the heap alike.
            ).

    % `tf_front` is empty only when the queue is.
    %
:- type ttl_fifo
    --->    ttl_fifo(
                tf_front :: list({instant, int, fact_id}),
                tf_back  :: list({instant, int, fact_id}),
                            % Newest first.
                tf_last  :: instant
                            % The latest deadline this FIFO has taken.
            ).

:- type ttl_source
    --->    from_fifo(uint32)
    ;       from_heap.

:- func init_ttl_queue = ttl_queue.

init_ttl_queue = ttl_queue(map.init, pqueue.init, 0).

:- pred ttl_arm(instant::in, uint32::in, fact_id::in,
                ttl_queue::in, ttl_queue::out) is det.

ttl_arm(At, SchemaKey, Id, !Q) :-
    Seq = !.Q ^ tq_next,
    !Q ^ tq_next := Seq + 1,
    Entry = {At, Seq, Id},
    Fifos0 = !.Q ^ tq_fifos,
    ( if map.search(Fifos0, SchemaKey, ttl_fifo(Front, Back, Last)) then
        ( if Front = [] then
            !Q ^ tq_fifos := map.det_update(Fifos0, SchemaKey,
                ttl_fifo([Entry], [], At))
        else if not before(At, Last) then
            !Q ^ tq_fifos := map.det_update(Fifos0, SchemaKey,
                ttl_fifo(Front, [Entry | Back], At))
        else
            pqueue.insert({At, Seq}, Id, !.Q ^ tq_heap, Heap),
            !Q ^ tq_heap := Heap
        )
    else
        !Q ^ tq_fifos := map.det_insert(Fifos0, SchemaKey,
            ttl_fifo([Entry], [], At))
    ).

:- pred ttl_earliest(ttl_queue::in, {instant, int}::out, ttl_source::out)
    is semidet.

ttl_earliest(Q, Key, Source) :-
    HeapHead = ( if pqueue.peek(Q ^ tq_heap, K, _) then yes({K, from_heap})
                 else no ),
    map.foldl(fifo_head_min, Q ^ tq_fifos, HeapHead, Best),
    Best = yes({Key, Source}).

:- pred fifo_head_min(uint32::in, ttl_fifo::in,
                      maybe({{instant, int}, ttl_source})::in,
                      maybe({{instant, int}, ttl_source})::out) is det.

fifo_head_min(SchemaKey, Fifo, Best0, Best) :-
    ( if
        Fifo ^ tf_front = [{At, Seq, _} | _],
        (
            Best0 = no
        ;
            Best0 = yes({Key0, _}),
            compare((<), {At, Seq}, Key0)
        )
    then
        Best = yes({{At, Seq}, from_fifo(SchemaKey)})
    else
        Best = Best0
    ).

:- pred ttl_pop(ttl_source::in, fact_id::out, ttl_queue::in, ttl_queue::out)
    is semidet.

ttl_pop(from_heap, Id, !Q) :-
    pqueue.remove(_, Id, !.Q ^ tq_heap, Heap),
    !Q ^ tq_heap := Heap.
ttl_pop(from_fifo(SchemaKey), Id, !Q) :-
    map.search(!.Q ^ tq_fifos, SchemaKey, ttl_fifo(Front0, Back, Last)),
    Front0 = [{_, _, Id} | Front1],
    ( if Front1 = [] then
        Fifo = ttl_fifo(list.reverse(Back), [], Last)
    else
        Fifo = ttl_fifo(Front1, Back, Last)
    ),
    !Q ^ tq_fifos := map.det_update(!.Q ^ tq_fifos, SchemaKey, Fifo).

:- pred ttl_due(instant::in, list(fact_id)::out,
                ttl_queue::in, ttl_queue::out) is det.

ttl_due(Now, list.reverse(Rev), !Q) :-
    ttl_due_loop(Now, [], Rev, !Q).

:- pred ttl_due_loop(instant::in, list(fact_id)::in, list(fact_id)::out,
                     ttl_queue::in, ttl_queue::out) is det.

ttl_due_loop(Now, Acc, Ids, !Q) :-
    ( if
        ttl_earliest(!.Q, {At, _}, Source),
        not before(Now, At),
        ttl_pop(Source, Id, !.Q, Q1)
    then
        ttl_due_loop(Now, [Id | Acc], Ids, Q1, !:Q)
    else
        Ids = Acc
    ).

%-----------------------------------------------------------------------------%

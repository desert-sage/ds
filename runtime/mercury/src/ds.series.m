% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.series -- the seven series backings, their atoms, and their state.
%
% `query` takes the state `in`, so a read changes nothing [RDSC.5a.1a]. State
% changes on absorption, and eviction happens there.
%-----------------------------------------------------------------------------%

:- module ds.series.
:- interface.

:- import_module bool.
:- import_module ds.atom.
:- import_module ds.chrono.
:- import_module ds.value.
:- import_module ds.wire.
:- import_module list.
:- import_module string.

%-----------------------------------------------------------------------------%
% The declaration, as the artefact carries it
%-----------------------------------------------------------------------------%

    % The compiler picks the backing [RDSC.5a.2]; an author never names it.
    %
:- type backing
    --->    bk_welford         % running stats, all_time
    ;       bk_ring_buffer     % exact samples, sliding
    ;       bk_monotonic_deque % exact min/max, sliding
    ;       bk_fifo_deque      % first / bool_and / bool_or
    ;       bk_reservoir       % sample <n>
    ;       bk_interval_pulse  % active_fraction
    ;       bk_numeric_integral. % integral

    % Each backing's atom in [RDSC.7.1], both ways.
    %
:- pred atom_of_backing(backing, atom_id).
:- mode atom_of_backing(in, out) is det.
:- mode atom_of_backing(out, in) is semidet.

    % `el_unspecified` is what a backing with no `element_type` field decodes
    % to. `SeriesBackendIntervalPulse` has none: its element type is always Bool.
    %
:- type element_type
    --->    el_unspecified
    ;       el_float
    ;       el_int
    ;       el_string
    ;       el_bool.

:- type time_model
    --->    tm_unspecified
    ;       tm_sliding
    ;       tm_all_time
    ;       tm_tumbling.

:- type gap_policy
    --->    gp_unspecified
    ;       gp_hold
    ;       gp_zero
    ;       gp_skip.

    % The declaration's `nulls:` option [LNUL.8.6], not `gap_policy`.
    % `np_unspecified` is a series over a non-nullable source.
    %
:- type null_policy
    --->    np_unspecified
    ;       np_skip
    ;       np_hold
    ;       np_zero.

:- type series_decl
    --->    series_decl(
                sd_backing  :: backing,
                sd_schema   :: string,
                sd_slot     :: string,
                sd_id_slot  :: string,      % "" is `by: none` [LSER.7.6.2]
                sd_element  :: element_type,
                sd_window   :: uint64,      % ns; 0 = all_time / reservoir
                sd_persist  :: uint64,      % 0 = live-only
                sd_max      :: uint32,      % 0 = window is the only bound
                sd_time     :: time_model,  % SeriesBackendNumericIntegral only
                sd_gap      :: gap_policy,  % SeriesBackendNumericIntegral only
                sd_nulls    :: null_policy  % [LNUL.8.6]; every backing
            ).

    % Decode one backend atom body. The `backing` says which layout to read.
    %
:- pred decode_backing(backing::in, reader::in, series_decl::out) is semidet.

%-----------------------------------------------------------------------------%
% What a series absorbs
%-----------------------------------------------------------------------------%

    % `specs/registry/series_storage_mode.ebnf`, named by `ds.names`. [NSTG.5]
    % is deferred, so nothing produces it.
    %
:- type storage_mode
    --->    sm_accumulator
    ;       sm_ring_buffer.

    % Whether a value is a sample at all. A Time is already its `utc_ns` Int in
    % a slot.
    %
:- pred sampleable(ds_value::in) is semidet.

%-----------------------------------------------------------------------------%
% The row key
%-----------------------------------------------------------------------------%

    % One series row [RLOW.8.1]. The identity is stringified, so `int(1)` and
    % `str("1")` are one row. The window is in the key [RDSC.5a.8.1]. The
    % backing is the rest of that clause's tuple: the state keeps one row per
    % key and backing, so two backings at one window are parallel
    % [RDSC.5a.8.2] and each absorbs a sample once. A read names no backing,
    % and answers from the one libds would pick (`read_backing`).
    %
:- type series_key
    --->    series_key(
                sk_schema  :: string,
                sk_slot    :: string,
                sk_id_slot :: string,
                sk_id      :: string,       % "" for `by: none`
                sk_window  :: uint64        % ns; 0 = all_time
            ).

%-----------------------------------------------------------------------------%
% The aggregations
%-----------------------------------------------------------------------------%

:- type agg
    --->    agg_mean
    ;       agg_min
    ;       agg_max
    ;       agg_count
    ;       agg_sum
    ;       agg_first
    ;       agg_last
    ;       agg_variance        % sample (n-1)
    ;       agg_pvariance       % population (n)
    ;       agg_stdev
    ;       agg_pstdev
    ;       agg_rate             % SeriesBackendRingBuffer -- (last - first) / elapsed seconds
    ;       agg_direction        % SeriesBackendRingBuffer -- sign of the two newest [LSER.10.9]
    ;       agg_active_fraction  % SeriesBackendIntervalPulse -- time-weighted, Bool
    ;       agg_integral         % SeriesBackendNumericIntegral -- time-weighted, numeric
    ;       agg_bool_and         % SeriesBackendFifoDeque -- the only aggregations returning
    ;       agg_bool_or          %         a Bool rather than a number
    ;       agg_count_distinct   % SeriesBackendRingBuffer -- exact, sliding [LSER.16.5.2]
    ;       agg_percentile(int)  % SeriesBackendRingBuffer -- interpolated pNN, 1..99 [LSER.17.2]
    ;       agg_onset_rate       % SeriesBackendRingBuffer -- rising edges per second [LSIG.1.4.1]
    ;       agg_count_of(ds_value)
                                 % SeriesBackendRingBuffer -- occurrences of the
                                 % value [LSER.16.6.1]
    ;       agg_contains(ds_value).
                                 % SeriesBackendRingBuffer -- whether it occurs
                                 % [LSER.16.7.1]

%-----------------------------------------------------------------------------%
% State
%-----------------------------------------------------------------------------%

:- type series_state.

:- func init_series_state = series_state.

:- pred absorb(series_decl::in, series_key::in, ds_value::in, instant::in,
               series_state::in, series_state::out) is det.

    % Read an aggregation as of `Now`, answering `Zero` when the row does not
    % exist or holds nothing the aggregation can use [LSER.19.8].
    %
:- pred query(agg::in, series_key::in, instant::in,
              series_state::in, ds_value::in, ds_value::out) is det.

    % [LSER.19.8]'s cold value. The `bool` says whether the slot is declared Int.
    %
:- func cold_value(agg, bool) = ds_value.

    % For diagnostics.
    %
:- func row_count(series_state) = int.

    % The last value absorbed for a row, in the window or not: what `nulls: hold`
    % repeats [LNUL.8.6].
    %
:- pred held_value(series_key::in, series_state::in, ds_value::out)
    is semidet.

:- pred last_sample_at(series_key::in, series_state::in, instant::out)
    is semidet.

    % Whether this backing refuses at its declared capacity rather than drops
    % [LSIG.1.1]: the two step backings, on a window. An `integral all_time`
    % retains no samples, so no `capacity` binds it [LSER.13.14].
    %
:- pred lser_13_14_refuses(series_decl::in) is semidet.

    % Whether this reading reaches the backing, given whether the row holds a
    % value by this point in the pump's absorb order, and whether one is held
    % then ([LNUL.8.6]).
    %
    %@spec [LSER.13.14]
:- pred lser_13_14_absorbs(series_decl::in, ds_value::in, bool::in, bool::out)
    is semidet.

    % The samples a backing's row retains inside the window as of `Now`. The
    % carry is not one of them [LSER.13.14].
    %
:- func lser_13_14_retained(backing, series_key, instant, series_state) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.fault.
:- import_module ds.i64.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module math.
:- import_module maybe.
:- import_module uint32.
:- import_module uint64.

%-----------------------------------------------------------------------------%

atom_of_backing(bk_welford,          at_series_backend_welford_ewma).
atom_of_backing(bk_ring_buffer,      at_series_backend_ring_buffer).
atom_of_backing(bk_monotonic_deque,  at_series_backend_monotonic_deque).
atom_of_backing(bk_fifo_deque,       at_series_backend_fifo_deque).
atom_of_backing(bk_reservoir,        at_series_backend_reservoir).
atom_of_backing(bk_interval_pulse,   at_series_backend_interval_pulse).
atom_of_backing(bk_numeric_integral, at_series_backend_numeric_integral).

%-----------------------------------------------------------------------------%
% Decoding
%-----------------------------------------------------------------------------%

    % The field number of `window_ns` depends on the backing, and a misread is
    % silent:
    %
    %   window at 4, no element_type : SeriesBackendWelfordEwma (no
    %   max_samples), SeriesBackendMonotonicDeque, SeriesBackendReservoir
    %   window at 5, element at 4    : SeriesBackendRingBuffer,
    %   SeriesBackendFifoDeque, SeriesBackendNumericIntegral (+ time 8, gap 9)
    %   window at 5, field 4 a HOLE  : SeriesBackendIntervalPulse  -- always
    %   Bool, so no element_type
    %
:- type decl_acc
    --->    decl_acc(
                da_schema  :: string,
                da_slot    :: string,
                da_id      :: string,
                da_element :: element_type,
                da_window  :: uint64,
                da_persist :: uint64,
                da_max     :: uint32,
                da_time    :: time_model,
                da_gap     :: gap_policy,
                da_nulls   :: null_policy
            ).

decode_backing(Backing, R, Decl) :-
    Blank = decl_acc("", "", "", el_unspecified, 0u64, 0u64, 0u32,
        tm_unspecified, gp_unspecified, np_unspecified),
    ( if late_window(Backing) then
        fold_fields(R, late_field, Blank, ff_ok(A))
    else
        fold_fields(R, early_field, Blank, ff_ok(A))
    ),
    Decl = series_decl(Backing, A ^ da_schema, A ^ da_slot, A ^ da_id,
        A ^ da_element, A ^ da_window, A ^ da_persist, A ^ da_max,
        A ^ da_time, A ^ da_gap, A ^ da_nulls).

:- pred late_window(backing::in) is semidet.

late_window(bk_ring_buffer).
late_window(bk_fifo_deque).
late_window(bk_interval_pulse).
late_window(bk_numeric_integral).

    % Fields 1-3 and 11 are the same on all seven.
    %
:- pred common_field(uint32::in, field_value::in,
                     decl_acc::in, decl_acc::out) is semidet.

common_field(Num, Value, !A) :-
    ( if Num = 1u32 then
        Value = fv_bytes(S), reader_string(S, V), !A ^ da_schema := V
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, V), !A ^ da_slot := V
    else if Num = 3u32 then
        Value = fv_bytes(S), reader_string(S, V), !A ^ da_id := V
    else if Num = 11u32 then
        Value = fv_varint(V), nulls_of(V, N), !A ^ da_nulls := N
    else
        true
    ).

:- pred nulls_of(uint64::in, null_policy::out) is semidet.

nulls_of(0u64, np_unspecified).
nulls_of(1u64, np_skip).
nulls_of(2u64, np_hold).
nulls_of(3u64, np_zero).

:- pred early_field(uint32::in, field_value::in,
                    decl_acc::in, decl_acc::out) is semidet.

early_field(Num, Value, !A) :-
    ( if Num = 4u32 then
        Value = fv_varint(V), !A ^ da_window := V
    else if Num = 5u32 then
        Value = fv_varint(V), !A ^ da_persist := V
    else if Num = 6u32 then
        Value = fv_varint(V), !A ^ da_max := u32(V)
    else
        common_field(Num, Value, !A)
    ).

:- pred late_field(uint32::in, field_value::in,
                   decl_acc::in, decl_acc::out) is semidet.

late_field(Num, Value, !A) :-
    ( if Num = 4u32 then
        Value = fv_varint(V), element_of(V, E), !A ^ da_element := E
    else if Num = 5u32 then
        Value = fv_varint(V), !A ^ da_window := V
    else if Num = 6u32 then
        Value = fv_varint(V), !A ^ da_persist := V
    else if Num = 7u32 then
        Value = fv_varint(V), !A ^ da_max := u32(V)
    else if Num = 8u32 then
        Value = fv_varint(V), time_of(V, T), !A ^ da_time := T
    else if Num = 9u32 then
        Value = fv_varint(V), gap_of(V, G), !A ^ da_gap := G
    else
        common_field(Num, Value, !A)
    ).

:- pred element_of(uint64::in, element_type::out) is semidet.

element_of(0u64, el_unspecified).
element_of(1u64, el_float).
element_of(2u64, el_int).
element_of(3u64, el_string).
element_of(4u64, el_bool).

:- pred time_of(uint64::in, time_model::out) is semidet.

time_of(0u64, tm_unspecified).
time_of(1u64, tm_sliding).
time_of(2u64, tm_all_time).
time_of(3u64, tm_tumbling).

:- pred gap_of(uint64::in, gap_policy::out) is semidet.

gap_of(0u64, gp_unspecified).
gap_of(1u64, gp_hold).
gap_of(2u64, gp_zero).
gap_of(3u64, gp_skip).

:- func u32(uint64) = uint32.

u32(V) = uint32.cast_from_uint64(V).

%-----------------------------------------------------------------------------%
% What a series absorbs
%-----------------------------------------------------------------------------%

sampleable(int(_)).
sampleable(float(_)).
sampleable(bool(_)).
sampleable(str(_)).
sampleable(bytes(_)).

%-----------------------------------------------------------------------------%
% State
%-----------------------------------------------------------------------------%

    % One row shape for every backing but the reservoir: the samples, computed
    % over at the read. A `SeriesBackendWelfordEwma` row has window 0 and never
    % evicts.
    %
:- type row
    --->    row(
                rw_window  :: uint64,       % ns; 0 = unbounded
                rw_open    :: bool,
                            % Does the newest sample hold to the read instant?
                rw_samples :: list(sample), % newest first
                rw_first   :: instant,
                            % `t_first`, the row's first absorbed sample
                            % [LSER.19.7]. A row is never dropped, so it holds
                            % for the instance's life.
                rw_before  :: maybe(ds_value)
                            % The value of the sample just older than the
                            % oldest in `rw_samples`, once one has gone: the
                            % predecessor a rising edge is judged against
                            % [LSIG.1.4.1]. `no` while every sample is held,
                            % when the oldest held sample is the first
                            % absorbed and followed nothing.
            )
    ;       reservoir(
                rv_k      :: int,           % `max_samples`
                rv_n      :: int,           % total absorbed, ever
                rv_rng    :: uint64,        % xorshift64 state
                rv_slots  :: list(sample)   % index order, length =< k
            ).

:- type sample
    --->    sample(
                sm_at    :: instant,
                sm_value :: ds_value
            ).

    % [RDSC.5a.8.1]'s whole tuple: the series key and the backing.
    %
:- type row_key
    --->    row_key(
                rk_key     :: series_key,
                rk_backing :: backing
            ).

    % The rows, one per key and backing. What `nulls: hold` repeats is the
    % key's, whichever backing absorbed it [LNUL.8.6].
    %
:- type series_state
    --->    series_state(
                ss_rows :: map(row_key, row),
                ss_held :: map(series_key, ds_value)
            ).

init_series_state = series_state(map.init, map.init).

row_count(series_state(M, _)) = map.count(M).

held_value(Key, series_state(_, H), Value) :-
    map.search(H, Key, Value).

    % The newest sample of any backing's row for the key.
    %
last_sample_at(Key, series_state(M, _), At) :-
    Ats = list.filter_map(
        ( func(B) = A is semidet :-
            map.search(M, row_key(Key, B), Row),
            row_newest(Row, A)
        ), libds_slot_order),
    Ats = [First | Rest],
    At = list.foldl(later_instant, Rest, First).

:- pred row_newest(row::in, instant::out) is semidet.

row_newest(row(_, _, [sample(At, _) | _], _, _), At).
row_newest(reservoir(_, _, _, Slots), At) :-
    Slots = [sample(First, _) | Rest],
    At = list.foldl(later_of, Rest, First).

:- func later_instant(instant, instant) = instant.

later_instant(A, Best) =
    ( if instant_ns(A) > instant_ns(Best) then A else Best ).

:- func later_of(sample, instant) = instant.

later_of(sample(At, _), Best) =
    ( if instant_ns(At) > instant_ns(Best) then At else Best ).

absorb(Decl, Key, Value, Now, series_state(M0, H0), series_state(M, H)) :-
    map.set(Key, Value, H0, H),
    RowKey = row_key(Key, Decl ^ sd_backing),
    ( if Decl ^ sd_backing = bk_reservoir then
        ( if map.search(M0, RowKey, reservoir(K, N, Rng, Slots)) then
            Row0 = reservoir(K, N, Rng, Slots)
        else
            Row0 = reservoir(uint32.cast_to_int(Decl ^ sd_max), 0,
                golden_ratio_seed, [])
        ),
        map.set(RowKey, absorb_reservoir(sample(Now, Value), Row0), M0, M)
    else
        ( if map.search(M0, RowKey, row(_, _, Old, First0, Before0)) then
            ( if carry_backing(Decl ^ sd_backing) then
                Kept = evict_keeping_carry(Decl ^ sd_window, Now, Old)
            else
                Kept = evict(Decl ^ sd_window, Now, Old)
            ),
            First = First0,
            Prior = Before0,
            All = [sample(Now, Value) | Old]
        else
            Kept = [],
            First = Now,
            Prior = no,
            All = [sample(Now, Value)]
        ),
        Capped = cap(Decl, [sample(Now, Value) | Kept]),
        Before = lsig_1_4_1_before(Capped, All, Prior),
        map.set(RowKey,
            row(Decl ^ sd_window, open_tail(Decl), Capped, First, Before),
            M0, M)
    ).

    % [LSIG.1.4.1], [LSIG.1.1]: what the oldest held sample follows. The slot
    % holds its last absorbed value whatever the window or the cap discards.
    % Eviction and the cap each take an oldest run of `All`, so the samples
    % gone are the suffix after `Held`, and the newest of them is the
    % predecessor. A sample the cap drops takes its own edge with it, and no
    % other: the next sample is still judged against the one it followed.
    %
    %@spec [LSIG.1.4.1]
:- func lsig_1_4_1_before(list(sample), list(sample), maybe(ds_value))
    = maybe(ds_value).

lsig_1_4_1_before(Held, All, Before0) = Before :-
    ( if list.drop(list.length(Held), All, [sample(_, Gone) | _]) then
        Before = yes(Gone)
    else
        Before = Before0
    ).

    % The samples describe a step function: each value holds until the next
    % assertion [LSIG.1.3.1].
    %
:- pred step_backing(backing::in) is semidet.

step_backing(bk_interval_pulse).
step_backing(bk_numeric_integral).

    % The backings that store the carry: the step backings, and the ring buffer
    % for `onset_rate`'s predecessor [LSIG.1.4.1]. Its other reads filter by
    % age.
    %
:- pred carry_backing(backing::in) is semidet.

carry_backing(B) :- step_backing(B).
carry_backing(bk_ring_buffer).

    % [LSIG.1.4.1]. A rising edge is a `true` sample whose predecessor is
    % `false`. The first absorbed sample has none, and is no edge. `Samples` is
    % the window plus the carry, newest first,
    % and `Before` is what the oldest of them followed. `elapsed` counts from
    % `First`, the row's `t_first` [LSER.19.7], which neither the window nor
    % the cap moves.
    %
:- func onset_rate(uint64, instant, instant, maybe(ds_value), list(sample))
    = ds_value.

onset_rate(WindowNs, Now, First, Before, Samples) = float(Rate) :-
    NowNs = instant_ns(Now),
    FirstNs = instant_ns(First),
    Elapsed = ( if NowNs > FirstNs then NowNs - FirstNs else 0u64 ),
    Edges = rising_edges(WindowNs, NowNs, Before, Samples, 0),
    Denom = ( if WindowNs \= 0u64, WindowNs < Elapsed then WindowNs
              else Elapsed ),
    ( if Elapsed = 0u64 ; Edges = 0 ; Denom = 0u64 then
        Rate = 0.0
    else
        Rate = float.float(Edges * 1000000000) / uint64_to_float(Denom)
    ).

    % `Before` stands for the predecessor of the last sample in the list.
    %
:- func rising_edges(uint64, uint64, maybe(ds_value), list(sample), int) = int.

rising_edges(_, _, _, [], N) = N.
rising_edges(WindowNs, NowNs, Before, [sample(At, V) | Older], N0) = N :-
    AtNs = instant_ns(At),
    InWindow = ( if WindowNs = 0u64 ; NowNs < WindowNs ; AtNs > NowNs - WindowNs
                 then yes else no ),
    (
        Older = [sample(_, Prev) | _],
        Predecessor = yes(Prev)
    ;
        Older = [],
        Predecessor = Before
    ),
    ( if
        InWindow = yes,
        V = bool(yes),
        Predecessor = yes(bool(no))
    then
        N1 = N0 + 1
    else
        N1 = N0
    ),
    N = rising_edges(WindowNs, NowNs, Before, Older, N1).

    % `evict`, keeping the carry as well: the newest sample older than the
    % window, whose value holds into it [LSIG.2.5.1].
    %
:- func evict_keeping_carry(uint64, instant, list(sample)) = list(sample).

evict_keeping_carry(WindowNs, Now, Samples) = Kept :-
    ( if WindowNs = 0u64 then
        Kept = Samples
    else
        list.take_while(in_window(WindowNs, Now), Samples, Inside, Rest),
        (
            Rest = [Carry | _],
            Kept = Inside ++ [Carry]
        ;
            Rest = [],
            Kept = Inside
        )
    ).

:- func open_tail(series_decl) = bool.

open_tail(Decl) =
    ( if
        ( Decl ^ sd_backing = bk_interval_pulse
        ; Decl ^ sd_backing = bk_numeric_integral,
          ( Decl ^ sd_gap = gp_hold ; Decl ^ sd_gap = gp_unspecified )
        )
    then
        yes
    else
        no
    ).

%-----------------------------------------------------------------------------%
% The reservoir -- Algorithm R, bit-exactly
%-----------------------------------------------------------------------------%
%
% The generator advances only in the replacement phase: the first `k` samples
% draw nothing.

:- func golden_ratio_seed = uint64.

golden_ratio_seed = 0x9e3779b97f4a7c15u64.

:- func absorb_reservoir(sample, row) = row.

absorb_reservoir(S, Row0) = Row :-
    ( if Row0 = reservoir(K, N0, Rng0, Slots0) then
        N = N0 + 1,
        ( if list.length(Slots0) < K then
            Row = reservoir(K, N, Rng0, Slots0 ++ [S])
        else if K =< 0 then
            Row = reservoir(K, N, Rng0, Slots0)
        else
            J = rand_below(Rng0, N, Rng),
            ( if J < K then
                Row = reservoir(K, N, Rng, replace_nth(Slots0, J, S))
            else
                Row = reservoir(K, N, Rng, Slots0)
            )
        )
    else
        Row = Row0
    ).

:- func rand_below(uint64, int, uint64) = int.
:- mode rand_below(in, in, out) = out is det.

rand_below(State0, Bound, State) = Below :-
    State = xorshift64(State0),
    ( if Bound =< 0 then
        Below = 0
    else
        Below = uint64.cast_to_int(
            uint64.rem(State, uint64.det_from_int(Bound)))
    ).

:- func xorshift64(uint64) = uint64.

xorshift64(State0) = X3 :-
    ( if State0 = 0u64 then X0 = 0xdeadbeefcafebabeu64 else X0 = State0 ),
    X1 = X0 `xor` (X0 << 13),
    X2 = X1 `xor` (X1 >> 7),
    X3 = X2 `xor` (X2 << 17).

:- func replace_nth(list(sample), int, sample) = list(sample).

replace_nth(Slots, N, S) = Out :-
    ( if list.split_list(N, Slots, Before, [_ | After]) then
        Out = Before ++ [S | After]
    else
        Out = Slots
    ).

    % `window_ns = 0` means unbounded.
    %
:- func evict(uint64, instant, list(sample)) = list(sample).

evict(WindowNs, Now, Samples) =
    ( if WindowNs = 0u64 then
        Samples
    else
        list.filter(in_window(WindowNs, Now), Samples)
    ).

:- pred in_window(uint64::in, instant::in, sample::in) is semidet.

in_window(WindowNs, Now, sample(At, _)) :-
    Age = instant_ns(Now) - instant_ns(At),
    Age < WindowNs.
    % The half-open (t-W, t] of [LSER.14.1].

    % The drop arm of [LSER.13.14]. A step backing refuses at capacity, so
    % nothing here trims it.
    %
:- func cap(series_decl, list(sample)) = list(sample).

cap(Decl, Samples) = Kept :-
    Max = uint32.cast_to_int(Decl ^ sd_max),
    ( if Max = 0 ; step_backing(Decl ^ sd_backing) then
        Kept = Samples
    else
        Kept = list.take_upto(Max, Samples)
    ).

lser_13_14_refuses(Decl) :-
    step_backing(Decl ^ sd_backing),
    Decl ^ sd_max \= 0u32,
    Decl ^ sd_window \= 0u64.

lser_13_14_absorbs(Decl, Value, Held0, Held) :-
    ( if sampleable(Value) then
        Held = yes
    else
        Value = null,
        Policy = Decl ^ sd_nulls,
        (
            Policy = np_zero,
            Held = yes
        ;
            Policy = np_hold,
            Held0 = yes,
            Held = yes
        )
    ).

lser_13_14_retained(Backing, Key, Now, series_state(M, _)) = N :-
    ( if map.search(M, row_key(Key, Backing), row(W, _, Samples, _, _)) then
        N = list.length(list.filter(in_window(W, Now), Samples))
    else
        N = 0
    ).

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

query(Agg, Key, Now, series_state(M, _), Zero, Value) :-
    ( if
        Agg = agg_onset_rate,
        read_backing(Agg, Key, M, B),
        map.search(M, row_key(Key, B), row(W, _, All, First, Before))
    then
        Value = onset_rate(W, Now, First, Before,
            evict_keeping_carry(W, Now, All))
    else if
        read_backing(Agg, Key, M, B),
        map.search(M, row_key(Key, B), Row),
        ( if time_weighted(Agg), Row = row(W, _, All, _, _) then
            evict_keeping_carry(W, Now, All) = [S | Ss]
        else
            in_window_samples(Row, Now) = [S | Ss]
        )
    then
        ( if time_weighted(Agg) then
            Value = weighted(Agg, Zero, row_window(Row), row_open(Row), Now,
                [S | Ss])
        else
            Value = aggregate(moments_form(Row), Agg, Zero, [S | Ss])
        )
    else
        Value = Zero
    ).

    % The backing a read answers from, for parity with libds, whose read names
    % no backing either (`series_pick_backend_slot`): of the backings with a row
    % for the key that serve the aggregation, in libds's backend-slot order, an
    % unbounded read takes SeriesBackendWelfordEwma first and a windowed one
    % takes it last.
    %
:- pred read_backing(agg::in, series_key::in, map(row_key, row)::in,
                     backing::out) is semidet.

read_backing(Agg, Key, M, Backing) :-
    Served = list.filter(
        ( pred(B::in) is semidet :-
            serves(B, Agg),
            map.contains(M, row_key(Key, B))
        ), libds_slot_order),
    ( if Key ^ sk_window = 0u64, list.member(bk_welford, Served) then
        Backing = bk_welford
    else if
        list.find_first_match(
            ( pred(B::in) is semidet :- B \= bk_welford ), Served, Other)
    then
        Backing = Other
    else
        Served = [Backing | _]
    ).

    % libds's backend slots, in the order the engine registers them
    % (`ds_series_register_builtin_backends`, the ring buffer last).
    %
:- func libds_slot_order = list(backing).

libds_slot_order = [bk_welford, bk_monotonic_deque, bk_fifo_deque, bk_reservoir,
    bk_interval_pulse, bk_numeric_integral, bk_ring_buffer].

    % The aggregations each backing answers: libds's `supported_aggs` for its
    % vtable, a median being a 50th percentile here [LSER.17.2].
    %
:- pred serves(backing::in, agg::in) is semidet.

serves(bk_welford, Agg) :-
    ( Agg = agg_mean ; Agg = agg_stdev ; Agg = agg_pstdev
    ; Agg = agg_variance ; Agg = agg_pvariance ; Agg = agg_min ; Agg = agg_max
    ; Agg = agg_count ; Agg = agg_rate ; Agg = agg_direction ; Agg = agg_last
    ; Agg = agg_first ; Agg = agg_sum ; Agg = agg_bool_and ; Agg = agg_bool_or
    ).
serves(bk_reservoir, Agg) :-
    ( Agg = agg_mean ; Agg = agg_stdev ; Agg = agg_pstdev
    ; Agg = agg_variance ; Agg = agg_pvariance ; Agg = agg_min ; Agg = agg_max
    ; Agg = agg_sum ; Agg = agg_count ; Agg = agg_percentile(_)
    ; Agg = agg_bool_and ; Agg = agg_bool_or
    ).
serves(bk_fifo_deque, Agg) :-
    ( Agg = agg_first ; Agg = agg_last ; Agg = agg_bool_or ; Agg = agg_bool_and ).
serves(bk_monotonic_deque, Agg) :-
    ( Agg = agg_min ; Agg = agg_max ).
serves(bk_interval_pulse, agg_active_fraction).
serves(bk_numeric_integral, agg_integral).
serves(bk_ring_buffer, Agg) :-
    ( Agg = agg_mean ; Agg = agg_min ; Agg = agg_max ; Agg = agg_count
    ; Agg = agg_sum ; Agg = agg_stdev ; Agg = agg_pstdev ; Agg = agg_variance
    ; Agg = agg_pvariance ; Agg = agg_percentile(_) ; Agg = agg_count_distinct
    ; Agg = agg_count_of(_) ; Agg = agg_contains(_) ; Agg = agg_onset_rate
    ; Agg = agg_rate ; Agg = agg_direction
    ).

cold_value(agg_count, _) = int(0i64).
cold_value(agg_count_distinct, _) = int(0i64).
cold_value(agg_count_of(_), _) = int(0i64).
cold_value(agg_contains(_), _) = bool(no).
cold_value(agg_sum, IsInt) = preserving_zero(IsInt).
cold_value(agg_active_fraction, _) = float(0.0).
cold_value(agg_onset_rate, _) = float(0.0).
cold_value(agg_integral, _) = float(0.0).
cold_value(agg_percentile(_), _) = null.
cold_value(agg_bool_and, _) = null.
cold_value(agg_bool_or, _) = null.
cold_value(agg_min, _) = null.
cold_value(agg_max, _) = null.
cold_value(agg_first, _) = null.
cold_value(agg_last, _) = null.
cold_value(agg_mean, _) = null.
cold_value(agg_variance, _) = null.
cold_value(agg_pvariance, _) = null.
cold_value(agg_stdev, _) = null.
cold_value(agg_pstdev, _) = null.
cold_value(agg_rate, _) = null.
cold_value(agg_direction, _) = null.

:- func preserving_zero(bool) = ds_value.

preserving_zero(yes) = int(0i64).
preserving_zero(no) = float(0.0).

    % A read answers the window at the read [RDSC.5a.1a]: a sample in the window
    % when stored may not be now. A reservoir has no window.
    %
:- func in_window_samples(row, instant) = list(sample).

in_window_samples(row(Window, _, Samples, _, _), Now) =
    evict(Window, Now, Samples).
in_window_samples(reservoir(_, _, _, Slots), _) = Slots.

:- pred time_weighted(agg::in) is semidet.

time_weighted(agg_active_fraction).
time_weighted(agg_integral).

:- func row_window(row) = uint64.

row_window(row(W, _, _, _, _)) = W.
row_window(reservoir(_, _, _, _)) = 0u64.

:- func row_open(row) = bool.

row_open(row(_, Open, _, _, _)) = Open.
row_open(reservoir(_, _, _, _)) = no.

    % The signal aggregations, over the step function the samples describe. An
    % interval is clipped to the window at its old end, and `active_fraction`'s
    % denominator is the declared window [LSIG.2.2.3].
    %
:- func weighted(agg, ds_value, uint64, bool, instant, list(sample))
    = ds_value.

weighted(Agg, Zero, WindowNs, Open, Now, Samples) = Out :-
    ( if WindowNs = 0u64, Agg = agg_active_fraction then
        Out = Zero
    else
        ( if WindowNs = 0u64 then
            Start = 0u64
        else if instant_ns(Now) > WindowNs then
            Start = instant_ns(Now) - WindowNs
        else
            Start = 0u64
        ),
        % An open row's newest sample holds to `Now` [LSIG.2.2.3, LSIG.1.5.1].
        (
            Samples = [],
            Total = 0.0
        ;
            Samples = [sample(Newest, NewestV) | Older],
            NewestNs = instant_ns(Newest),
            ( if Open = yes, instant_ns(Now) > NewestNs then
                ( if NewestNs < Start then From = Start else From = NewestNs ),
                Tail = contribution(Agg, NewestV,
                    uint64_to_float(instant_ns(Now) - From))
            else
                Tail = 0.0
            ),
            Total = Tail + weigh(Agg, Start, NewestNs, Older, 0.0)
        ),
        (
            Agg = agg_active_fraction,
            Out = float(Total / uint64_to_float(WindowNs))
        ;
            Agg = agg_integral,
            Out = float(Total)
        ;
            ( Agg = agg_mean ; Agg = agg_min ; Agg = agg_max
            ; Agg = agg_count ; Agg = agg_sum ; Agg = agg_first
            ; Agg = agg_last ; Agg = agg_variance ; Agg = agg_pvariance
            ; Agg = agg_stdev ; Agg = agg_pstdev ; Agg = agg_rate
            ; Agg = agg_direction ; Agg = agg_bool_and ; Agg = agg_bool_or
            ; Agg = agg_count_distinct ; Agg = agg_percentile(_)
            ; Agg = agg_onset_rate ; Agg = agg_count_of(_) ; Agg = agg_contains(_) ),
            % Unreached: `query` sends only the time-weighted pair here.
            Out = Zero
        )
    ).

    % Walks newest-first, carrying the instant each interval ends at.
    %
:- func weigh(agg, uint64, uint64, list(sample), float) = float.

weigh(_, _, _, [], Acc) = Acc.
weigh(Agg, Start, EndNs, [sample(At, V) | Older], Acc) = Out :-
    AtNs = instant_ns(At),
    ( if AtNs < Start then From = Start else From = AtNs ),
    ( if EndNs > From then
        Span = uint64_to_float(EndNs - From)
    else
        Span = 0.0
    ),
    Contribution = contribution(Agg, V, Span),
    ( if AtNs =< Start then
        Out = Acc + Contribution
    else
        Out = weigh(Agg, Start, AtNs, Older, Acc + Contribution)
    ).

:- func contribution(agg, ds_value, float) = float.

contribution(Agg, V, Span) = Contribution :-
    (
        Agg = agg_active_fraction,
        ( if V = bool(yes) then Contribution = Span else Contribution = 0.0 )
    ;
        Agg = agg_integral,
        % Value times seconds.
        ( if numeric(V, N) then
            Contribution = N * Span / 1000000000.0
        else
            Contribution = 0.0
        )
    ;
        ( Agg = agg_mean ; Agg = agg_min ; Agg = agg_max ; Agg = agg_count
        ; Agg = agg_sum ; Agg = agg_first ; Agg = agg_last
        ; Agg = agg_variance ; Agg = agg_pvariance ; Agg = agg_stdev
        ; Agg = agg_pstdev ; Agg = agg_rate ; Agg = agg_direction
        ; Agg = agg_bool_and ; Agg = agg_bool_or
        ; Agg = agg_count_distinct ; Agg = agg_percentile(_)
        ; Agg = agg_onset_rate ; Agg = agg_count_of(_) ; Agg = agg_contains(_) ),
        Contribution = 0.0
    ).

:- pred numeric(ds_value::in, float::out) is semidet.

numeric(float(F), F).
numeric(int(I), i64.to_float(I)).

:- func uint64_to_float(uint64) = float.

uint64_to_float(V) = float.float(uint64.cast_to_int(V)).

:- func aggregate(moments_form, agg, ds_value, list(sample)) = ds_value.

aggregate(_, agg_count, _, Ss) = int(int64.from_int(list.length(Ss))).
aggregate(_, agg_first, Zero, Ss) = last_value(Zero, Ss).
aggregate(_, agg_last, _, [S | _]) = S ^ sm_value.
aggregate(_, agg_last, Zero, []) = Zero.
aggregate(Form, agg_mean, Zero, Ss) = moment(Form, m_mean, Zero, Ss).
aggregate(Form, agg_sum, Zero, Ss) = Out :-
    ( if int_samples(Ss, Is), Is = [_ | _] then
        % [LSER.17.2]: wraps.
        Out = int(list.foldl(func(I, Acc) = Acc + I, Is, 0i64))
    else
        % [LSER.16.3.3]: a left fold in the backing's order.
        Ns = numbers(in_order(Form, Ss)),
        ( if Ns = [_ | _] then
            Out = float(list.foldl(func(X, Acc) = Acc + X, Ns, 0.0))
        else
            Out = Zero
        )
    ).
    % [LSER.16.9]. `Ss` is newest-first. No elapsed time answers `Zero`.
aggregate(_, agg_rate, Zero, Ss) = Out :-
    ( if
        Ss = [sample(NewAt, NewV) | _],
        list.last(Ss, sample(OldAt, OldV)),
        numeric(NewV, NewN),
        numeric(OldV, OldN),
        NewNs = instant_ns(NewAt),
        OldNs = instant_ns(OldAt),
        NewNs > OldNs
    then
        Out = float((NewN - OldN) * 1000000000.0
                    / uint64_to_float(NewNs - OldNs))
    else
        Out = Zero
    ).
aggregate(_, agg_min, Zero, Ss) = extreme(Zero, Ss, signed_min,
    (func(A, B) = ( if A =< B then A else B ))).
aggregate(_, agg_max, Zero, Ss) = extreme(Zero, Ss, signed_max,
    (func(A, B) = ( if A >= B then A else B ))).
aggregate(Form, agg_variance, Zero, Ss) = moment(Form, m_var, Zero, Ss).
aggregate(Form, agg_pvariance, Zero, Ss) = moment(Form, m_pvar, Zero, Ss).
aggregate(Form, agg_stdev, Zero, Ss) = moment(Form, m_stdev, Zero, Ss).
aggregate(Form, agg_pstdev, Zero, Ss) = moment(Form, m_pstdev, Zero, Ss).
aggregate(_, agg_bool_and, Zero, Ss) = bool_fold(Zero, Ss, yes).
aggregate(_, agg_bool_or, Zero, Ss) = bool_fold(Zero, Ss, no).
aggregate(_, agg_count_distinct, _, Ss) =
    int(int64.from_int(list.length(list.sort_and_remove_dups(
        list.map((func(sample(_, V)) = V), Ss))))).
    % Unreached: `query` answers `onset_rate` before the general read.
aggregate(_, agg_onset_rate, Zero, _) = Zero.
    % A lookup of a kind `sample_matches` does not name, `null` included, matches
    % nothing. The caller interns a computed String first.
aggregate(_, agg_count_of(Lookup), _, Ss) =
    int(int64.from_int(list.length(list.filter(sample_matches(Lookup), Ss)))).
aggregate(_, agg_contains(Lookup), _, Ss) =
    bool(( if list.any_true(sample_matches(Lookup), Ss) then yes else no )).
    % [LSER.17.2]. The rank stays in integers.
aggregate(_, agg_percentile(P0), Zero, Ss) = Out :-
    list.sort(signed_float_order, numbers(Ss), Sorted),
    N = list.length(Sorted),
    ( if N > 0 then
        P = int.max(0, int.min(100, P0)),
        Num = (N - 1) * P,
        Lo = Num // 100,
        Frac = Num rem 100,
        XLo = list.det_index0(Sorted, Lo),
        ( if Frac = 0 then
            Out = float(XLo)
        else
            XHi = list.det_index0(Sorted, Lo + 1),
            ( if
                ( XLo = XHi
                ; XLo = -float.infinity, XHi \= float.infinity
                )
            then
                Out = float(XLo)
            else
                D = XHi - XLo,
                F = float.float(Frac) / 100.0,
                M = F * D,
                Out = float(XLo + M)
            )
        )
    else
        Out = Zero
    ).
    % [LSER.10.9]: compared, never subtracted. `Ss` is newest-first.
aggregate(_, agg_direction, Zero, Ss) = Out :-
    ( if
        Ss = [sample(_, New), sample(_, Prev) | _],
        compare_samples(New, Prev, Sign)
    then
        Out = int(Sign)
    else
        Out = Zero
    ).

:- pred compare_samples(ds_value::in, ds_value::in, int64::out) is semidet.

compare_samples(New, Prev, Sign) :-
    ( if New = int(A), Prev = int(B) then
        Sign = ( if A > B then 1i64 else if A < B then -1i64 else 0i64 )
    else
        numeric(New, X),
        numeric(Prev, Y),
        Sign = ( if X > Y then 1i64 else if X < Y then -1i64 else 0i64 )
    ).

    % Ascending, -0 before +0 ([LSER.17.2]). No NaN reaches a series
    % ([LEXP.4.2]).
    %
:- pred signed_float_order(float::in, float::in, comparison_result::out)
    is det.

signed_float_order(A, B, R) :-
    ( if A < B then
        R = (<)
    else if A > B then
        R = (>)
    else if negative_zero(A), not negative_zero(B) then
        R = (<)
    else if negative_zero(B), not negative_zero(A) then
        R = (>)
    else
        R = (=)
    ).

    % [LSER.17.2]: `min` and `max` select under `signed_float_order`, so of
    % the two zeros `min` is -0 and `max` is +0 whatever order they arrived in.
    % `float.min` and `float.max` return one of two equal arguments, which
    % left the answer to the order a backing keeps its samples in.
    %
:- func signed_min(float, float) = float.

signed_min(A, B) = Min :-
    signed_float_order(A, B, R),
    ( if R = (>) then Min = B else Min = A ).

:- func signed_max(float, float) = float.

signed_max(A, B) = Max :-
    signed_float_order(A, B, R),
    ( if R = (<) then Max = B else Max = A ).

    % `unchecked_quotient` because `/` refuses a zero divisor.
    %
:- pred negative_zero(float::in) is semidet.

negative_zero(F) :-
    F = 0.0,
    float.unchecked_quotient(1.0, F) < 0.0.

    % [LSER.16.5.1]'s equality, for `count_of` and `contains`. A Time slot's
    % samples are its stored Int, the instant (`stored_value`), and the caller
    % takes a Time lookup to the same, so no Time reaches here: one instant at
    % any offset is one value ([LTIM.5.2]). The standard order `count_distinct`
    % sorts by holds -0.0 and 0.0 equal, as `==` does.
    %
:- pred sample_matches(ds_value::in, sample::in) is semidet.

sample_matches(Lookup, sample(_, V)) :-
    ( if Lookup = int(I), V = float(F) then
        i64.to_float(I) = F
    else if Lookup = float(F), V = int(I) then
        i64.to_float(I) = F
    else
        ( Lookup = int(_) ; Lookup = float(_) ; Lookup = str(_)
        ; Lookup = bool(_) ),
        Lookup = V
    ).

    % `Want = yes` is `and`; `Want = no` is `or`.
    %
:- func bool_fold(ds_value, list(sample), bool) = ds_value.

bool_fold(Zero, Ss, Want) = Out :-
    Bools = list.filter_map(as_bool, Ss),
    (
        Bools = [],
        Out = Zero
    ;
        Bools = [_ | _],
        ( if list.member(B, Bools), B \= Want then
            Out = bool(negate(Want))
        else
            Out = bool(Want)
        )
    ).

:- func as_bool(sample) = bool is semidet.

as_bool(sample(_, bool(B))) = B.

:- func negate(bool) = bool.

negate(yes) = no.
negate(no) = yes.
    % Unreached: `query` routes these to `weighted`.
aggregate(_, agg_active_fraction, Zero, _) = Zero.
aggregate(_, agg_integral, Zero, _) = Zero.

:- func last_value(ds_value, list(sample)) = ds_value.

last_value(Zero, []) = Zero.
last_value(_, [S]) = S ^ sm_value.
last_value(Zero, [_, S1 | Ss]) = last_value(Zero, [S1 | Ss]).

    % Ints widen to Float; anything non-numeric is dropped.
    %
:- func numbers(list(sample)) = list(float).

numbers([]) = [].
numbers([sample(_, V) | Ss]) =
    ( if V = float(F) then [F | numbers(Ss)]
      else if V = int(I) then [i64.to_float(I) | numbers(Ss)]
      else numbers(Ss) ).

    % `sum`, `min` and `max` over an `Int` slot are computed in `int64`
    % ([LSER.17.2]). A bag of `int` samples is an `Int` slot.
    %
:- pred int_samples(list(sample)::in, list(int64)::out) is semidet.

int_samples([], []).
int_samples([sample(_, int(I)) | Ss], [I | Is]) :-
    int_samples(Ss, Is).

:- func extreme(ds_value, list(sample), func(float, float) = float,
    func(int64, int64) = int64) = ds_value.

extreme(Zero, Ss, PickF, PickI) = Out :-
    ( if int_samples(Ss, [I | Is]) then
        Out = int(list.foldl(PickI, Is, I))
    else
        Ns = numbers(Ss),
        (
            Ns = [],
            Out = Zero
        ;
            Ns = [N | Rest],
            Out = float(list.foldl(PickF, Rest, N))
        )
    ).

%-----------------------------------------------------------------------------%
% `mean` and the dispersion stats -- one order of steps per backing
%-----------------------------------------------------------------------------%
%
% [LSER.16.3.3] fixes each form and its order. The forms' `n <= 1` guards on
% `Var` stay because `Var` is bound for every moment, and Mercury's float `/`
% throws on a zero divisor.

:- type moments_form
    --->    mf_accumulator      % SeriesBackendWelfordEwma
    ;       mf_reservoir        % SeriesBackendReservoir
    ;       mf_two_pass.        % SeriesBackendRingBuffer

:- func moments_form(row) = moments_form.

moments_form(row(Window, _, _, _, _)) =
    ( if Window = 0u64 then mf_accumulator else mf_two_pass ).
moments_form(reservoir(_, _, _, _)) = mf_reservoir.

    % [LSER.16.3.3]'s sample order for the backing: a row's samples are newest
    % first, and a reservoir's in slot order.
    %
:- func in_order(moments_form, list(sample)) = list(sample).

in_order(mf_accumulator, Ss) = list.reverse(Ss).
in_order(mf_two_pass, Ss) = list.reverse(Ss).
in_order(mf_reservoir, Ss) = Ss.

:- type moment
    --->    m_mean
    ;       m_var
    ;       m_pvar
    ;       m_stdev
    ;       m_pstdev.

:- func moment(moments_form, moment, ds_value, list(sample)) = ds_value.

moment(Form, Moment, Zero, Ss) = Out :-
    Ns = numbers(in_order(Form, Ss)),
    (
        Ns = [],
        Out = Zero
    ;
        Ns = [First | Rest],
        ( if
            Rest = [],
            ( Moment = m_var
            ; Moment = m_stdev
            )
        then
            Out = null
        else
        (
            Form = mf_accumulator,
            list.foldl3(welford_step, Rest, 1.0, W, First, Mean, 0.0, M2),
            Var = ( if W =< 1.0 then 0.0 else M2 / (W - 1.0) ),
            PVar = ( if W =< 0.0 then 0.0 else M2 / W ),
            Out = float(pick(Moment, Mean, Var, PVar,
                (func(V) = guarded_sqrt(V))))
        ;
            Form = mf_reservoir,
            list.foldl3(reservoir_step, Ns, 0, N, 0.0, Mean, 0.0, M2),
            Var = ( if N > 1 then M2 / float.float(N - 1) else 0.0 ),
            PVar = M2 / float.float(N),
            Out = float(pick(Moment, Mean, Var, PVar,
                (func(V) = math.sqrt(V))))
        ;
            Form = mf_two_pass,
            N = list.length(Ns),
            Mean = list.foldl(func(X, Acc) = Acc + X, Ns, 0.0)
                / float.float(N),
            SS = list.foldl(
                (func(X, Acc) = R :- D = X - Mean, R = Acc + D * D), Ns, 0.0),
            Var = ( if N =< 1 then 0.0 else SS / float.float(N - 1) ),
            PVar = SS / float.float(N),
            Out = float(pick(Moment, Mean, Var, PVar,
                (func(V) = guarded_sqrt(V))))
        )
        )
    ).

:- pred welford_step(float::in, float::in, float::out, float::in, float::out,
                     float::in, float::out) is det.

welford_step(X, W0, W, Mean0, Mean, M20, M2) :-
    W = W0 + 1.0,
    D = X - Mean0,
    Mean = Mean0 + D / W,
    M2 = M20 + D * (X - Mean).

:- pred reservoir_step(float::in, int::in, int::out, float::in, float::out,
                       float::in, float::out) is det.

reservoir_step(X, I, I1, Mean0, Mean, M20, M2) :-
    I1 = I + 1,
    D = X - Mean0,
    Mean = Mean0 + D / float.float(I + 1),
    M2 = M20 + D * (X - Mean).

:- func pick(moment, float, float, float, (func(float) = float)) = float.

pick(m_mean, Mean, _, _, _) = Mean.
pick(m_var, _, Var, _, _) = Var.
pick(m_pvar, _, _, PVar, _) = PVar.
pick(m_stdev, _, Var, _, Sqrt) = Sqrt(Var).
pick(m_pstdev, _, _, PVar, Sqrt) = Sqrt(PVar).

:- func guarded_sqrt(float) = float.

guarded_sqrt(V) = ( if V > 0.0 then math.sqrt(V) else 0.0 ).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.chrono -- time quantities and the clock.
%
% Not `ds.time`, which shadows the standard library's `time`.
%
% Only `read_wall_clock`, the host's to take, reads host time [RARC.13.10]: the
% `foreign_proc` is private and a `wall_reading` is abstract.
%
% Two clocks, one sample per step ([LTIM.2.8]). The clock is a source, what it
% would read now, and a held sample. `clock_sample` copies the source into the
% sample when the engine consumes an input or begins a pump, and every read
% returns the sample. Mutations and observations move the source only
% ([NTST.3.3]).
%
% The wall clock may have no value: `no` is not the epoch.
%-----------------------------------------------------------------------------%

:- module ds.chrono.
:- interface.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% Quantities
%-----------------------------------------------------------------------------%

    % An instant on the engine's monotonic clock, re-driven from recorded values
    % on replay. Events are ordered by `seq`, never by its low bits [RFCS.6.6].
    %
:- type instant.

:- type duration.

    % A DS `Time` value [LTIM.1.1.1], not convertible to an `instant` without an
    % anchor. Ordering, equality and arithmetic use `utc_ns` alone [LTIM.1.1.2].
    %
:- type ds_time.

:- func ds_time(int64, int64) = ds_time.    % utc_ns, tz_offset_ns
:- func utc_ns(ds_time) = int64.
:- func tz_offset_ns(ds_time) = int64.

    % What storing a `Time` does: a slot keeps `utc_ns` only ([LTIM.1.1.3]).
    %
:- func to_utc(ds_time) = ds_time.

:- func local_ns(ds_time) = int64.

    % [LTIM.1.2.2]: the days whose midnight in UTC is a representable `Time`,
    % 1677-09-22 (-106751) through 2262-04-11 (106751).
    %
:- func ltim_1_2_2_date_min = int64.
:- func ltim_1_2_2_date_max = int64.
:- pred ltim_1_2_2_date_in_range(int64::in) is semidet.

    % The proleptic Gregorian calendar ([LTIM.1.2.4]). Exact for a year within
    % 10^15 either way.
    %
:- func ltim_days_from_civil(int64, int64, int64) = int64.
:- func ltim_days_in_month(int64, int64) = int64.

    % [LTIM.14.2], for fields that are all present `Int`s: `ds.eval` evaluates a
    % call with this, and the compiler folds one with it ([LTIM.14.3]). The value
    % is a `Time`'s `utc_ns` or a `Date`'s day count.
    %
:- type ltim_14_2_answer
    --->    calendar_value(int64)
    ;       calendar_domain
    ;       calendar_not_representable.

    % (year, month, day, hour, minute, second, nanosecond).
    %
:- func ltim_14_2_time(int64, int64, int64, int64, int64, int64, int64)
    = ltim_14_2_answer.

    % (year, month, day).
    %
:- func ltim_14_2_date(int64, int64, int64) = ltim_14_2_answer.

:- func instant_ns(instant) = uint64.
:- func duration_ns(duration) = uint64.
:- func from_ns(uint64) = instant.
:- func duration_from_ns(uint64) = duration.

:- func add(instant, duration) = instant.
:- func diff(instant, instant) = duration.      % saturating at zero
:- pred before(instant::in, instant::in) is semidet.

%-----------------------------------------------------------------------------%
% The clock
%-----------------------------------------------------------------------------%

    % A source, a held sample, and the mode.
    %
:- type clock.

    % [RTIM.3.1.1].
    %
:- type clock_mode
    --->    live
    ;       mock.

    % What a sample was taken for ([LTIM.2.8.4]).
    %
:- type clock_step
    --->    step_input
    ;       step_pump.

    % The held monotonic sample ([LTIM.2.8.2]).
    %
:- func clock_now(clock) = instant.

    % The held wall sample ([LTIM.2.8.3]), UTC ns since the Unix epoch.
    %
:- func clock_wall(clock) = maybe(int64).

    % The source's monotonic value, for the integrator's read. Not a sample;
    % nothing in the engine reads it.
    %
:- func clock_source_now(clock) = instant.

    % As `clock_source_now`, for the wall clock.
    %
:- func clock_source_wall(clock) = maybe(int64).

:- func mode_of(clock) = clock_mode.

    % A live clock at an instant, with no wall value, until its first
    % `clock_observe`.
    %
:- func init_clock(instant) = clock.

    % The mock monotonic clock starts at 0 and the wall clock unset. Fails once
    % the clock has been sampled ([NLFC.5.4]). Already mock: unchanged.
    %
:- pred clock_to_mock(clock::in, clock::out) is semidet.

    % `Record` is `yes` when the sample must go on the trace ([LTIM.2.8.5]). The
    % caller records it, before the step's own record, and marks it with
    % `clock_mark_recorded`.
    %
:- pred clock_sample(clock_step::in, bool::out, clock::in, clock::out) is det.
:- pred clock_mark_recorded(clock::in, clock::out) is det.

    % Before the first sample the held monotonic value means nothing
    % ([LTIM.2.8.2]).
    %
:- pred clock_sampled(clock::in) is semidet.

    % [LTIM.1.1.5]: the instant plus the window would pass INT64_MAX, so the
    % deadline has no value. Written so the bound cannot overflow. A zero window
    % is no deadline.
    %
:- pred ltim_1_1_5_deadline_past_range(instant::in, duration::in) is semidet.

    % The mock setters. Each fails on a live clock. Not samples ([NTST.3.3]).
    %
    % `clock_set` fails below the current value once the engine has sampled
    % ([NTST.3.1]). `clock_advance` also moves a wall clock that has a value, and
    % fails as `ntst_3_1_advance_past_range` says.
    %
:- pred clock_advance(duration::in, clock::in, clock::out) is semidet.
:- pred clock_set(instant::in, clock::in, clock::out) is semidet.
:- pred clock_wall_set(int64::in, clock::in, clock::out) is semidet.

    % One that lands on the top of a range is taken, and a wall clock with no
    % value limits nothing.
    %
    %@spec [NTST.3.1]
:- pred ntst_3_1_advance_past_range(duration::in, clock::in) is semidet.

    % Replay's alone, for a `ClockAdvance` recorded with `has_wall` false
    % ([RFCS.10.5]).
    %
:- pred clock_wall_unset(clock::in, clock::out) is semidet.

    % One reading of the host's two clocks, taken together.
    %
:- type wall_reading.

:- pred read_wall_clock(wall_reading::out, io::di, io::uo) is det.

    % Moves a live clock's source; not a sample. Fails on a mock clock. The first
    % reading anchors the monotonic clock at its current instant; later readings
    % move it by the time since, never backward. The wall part may move either
    % way ([LTIM.2.8.3]).
    %
:- pred clock_observe(wall_reading::in, clock::in, clock::out) is semidet.

%-----------------------------------------------------------------------------%
% Deadlines
%-----------------------------------------------------------------------------%

    % Only the unit suite uses this.
    %
:- type deadlines(Client).

:- func init_deadlines = deadlines(Client).

:- pred arm(instant::in, Client::in,
            deadlines(Client)::in, deadlines(Client)::out) is det.

    % Every client due at the instant, removed, by deadline then arm order.
    %
:- pred due(instant::in, list(Client)::out,
            deadlines(Client)::in, deadlines(Client)::out) is det.

:- pred next_deadline(deadlines(Client)::in, instant::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module uint64.
:- import_module int.
:- import_module int64.
:- import_module integer.

:- type deadlines(Client) ---> deadlines(list({instant, int, Client}), int).
    % Entries plus the arm counter.

:- type instant ---> instant(uint64).
:- type duration ---> duration(uint64).

:- type ds_time ---> zoned(int64, int64).   % utc_ns, tz_offset_ns

ds_time(Utc, Tz) = zoned(Utc, Tz).

utc_ns(zoned(U, _)) = U.
tz_offset_ns(zoned(_, T)) = T.

to_utc(zoned(U, _)) = zoned(U, 0i64).

local_ns(zoned(U, T)) = U + T.

ltim_1_2_2_date_min = -106751i64.
ltim_1_2_2_date_max = 106751i64.

ltim_1_2_2_date_in_range(Days) :-
    Days >= ltim_1_2_2_date_min,
    Days =< ltim_1_2_2_date_max.

    % Hinnant's `days_from_civil`.
    %
ltim_days_from_civil(Y0, M, D) = Era * 146097i64 + Doe - 719468i64 :-
    Y = ( if M =< 2i64 then Y0 - 1i64 else Y0 ),
    Era = Y div 400i64,
    Yoe = Y - Era * 400i64,
    Mp = ( if M > 2i64 then M - 3i64 else M + 9i64 ),
    Doy = (153i64 * Mp + 2i64) // 5i64 + D - 1i64,
    Doe = Yoe * 365i64 + Yoe // 4i64 - Yoe // 100i64 + Doy.

ltim_days_in_month(Y, M) = Days :-
    ( if M = 2i64 then
        Days = ( if ltim_leap_year(Y) then 29i64 else 28i64 )
    else if ( M = 4i64 ; M = 6i64 ; M = 9i64 ; M = 11i64 ) then
        Days = 30i64
    else
        Days = 31i64
    ).

:- pred ltim_leap_year(int64::in) is semidet.

ltim_leap_year(Y) :-
    ( Y rem 4i64 = 0i64, Y rem 100i64 \= 0i64
    ; Y rem 400i64 = 0i64
    ).

    % The instant is computed whole, in `integer`, and only it is converted:
    % 1677-09-21's midnight is below the int64 minimum while its instants from
    % 00:12:43.145224192Z are not.
    %
ltim_14_2_time(Y, Mo, D, H, Mi, S, Ns) = Answer :-
    ( if
        ltim_14_2_day_in_range(Y, Mo, D),
        H >= 0i64, H =< 23i64,
        Mi >= 0i64, Mi =< 59i64,
        S >= 0i64, S =< 59i64,
        Ns >= 0i64, Ns =< 999999999i64
    then
        ( if
            ltim_14_2_days(Y, Mo, D, Days),
            integer.to_int64(
                integer.from_int64(Days)
                    * integer.from_int64(86400000000000i64)
                + integer.from_int64(
                    ((H * 60i64 + Mi) * 60i64 + S) * 1000000000i64 + Ns),
                Utc)
        then
            Answer = calendar_value(Utc)
        else
            Answer = calendar_not_representable
        )
    else
        Answer = calendar_domain
    ).

ltim_14_2_date(Y, Mo, D) = Answer :-
    ( if ltim_14_2_day_in_range(Y, Mo, D) then
        ( if
            ltim_14_2_days(Y, Mo, D, Days),
            ltim_1_2_2_date_in_range(Days)
        then
            Answer = calendar_value(Days)
        else
            Answer = calendar_not_representable
        )
    else
        Answer = calendar_domain
    ).

:- pred ltim_14_2_day_in_range(int64::in, int64::in, int64::in) is semidet.

ltim_14_2_day_in_range(Y, Mo, D) :-
    Mo >= 1i64,
    Mo =< 12i64,
    D >= 1i64,
    D =< ltim_days_in_month(Y, Mo).

    % Fails for a year past 10^15 either way, where `ltim_days_from_civil` stops
    % being exact.
    %
:- pred ltim_14_2_days(int64::in, int64::in, int64::in, int64::out)
    is semidet.

ltim_14_2_days(Y, Mo, D, Days) :-
    Y =< 1000000000000000i64,
    Y >= -1000000000000000i64,
    Days = ltim_days_from_civil(Y, Mo, D).

instant_ns(instant(N)) = N.
duration_ns(duration(N)) = N.
from_ns(N) = instant(N).
duration_from_ns(N) = duration(N).

add(instant(I), duration(D)) = instant(I + D).

diff(instant(A), instant(B)) =
    ( if A >= B then duration(A - B) else duration(0u64) ).

before(instant(A), instant(B)) :- A < B.

%-----------------------------------------------------------------------------%
% The clock
%-----------------------------------------------------------------------------%

:- type clock
    --->    clock(
                c_mode      :: clock_mode,

                c_src_mono  :: instant,
                c_src_wall  :: maybe(int64),
                c_anchor    :: maybe({uint64, instant}),
                            % A live clock's first monotonic reading and the
                            % instant it stood at then.
                c_held_mono :: instant,
                c_held_wall :: maybe(int64),
                c_recorded  :: maybe({instant, maybe(int64)}),
                c_sampled   :: bool
            ).

init_clock(At) = clock(live, At, no, no, At, no, no, no).

clock_now(C) = C ^ c_held_mono.
clock_wall(C) = C ^ c_held_wall.
clock_source_now(C) = C ^ c_src_mono.
clock_source_wall(C) = C ^ c_src_wall.
mode_of(C) = C ^ c_mode.

clock_to_mock(C0, C) :-
    Mode = C0 ^ c_mode,
    (
        Mode = mock,
        C = C0
    ;
        Mode = live,
        C0 ^ c_sampled = no,
        C = (((C0 ^ c_mode := mock)
                 ^ c_src_mono := instant(0u64))
                 ^ c_src_wall := no)
                 ^ c_anchor   := no
    ).

clock_sample(_Step, Record, C0, C) :-
    C =((C0 ^ c_held_mono := C0 ^ c_src_mono)
             ^ c_held_wall := C0 ^ c_src_wall)
             ^ c_sampled   := yes,
    ( if C ^ c_recorded = yes({C ^ c_held_mono, C ^ c_held_wall}) then
        Record = no
    else
        Record = yes
    ).

clock_mark_recorded(C0, C) :-
    C = C0 ^ c_recorded := yes({C0 ^ c_held_mono, C0 ^ c_held_wall}).

clock_sampled(C) :-
    C ^ c_sampled = yes.

ltim_1_1_5_deadline_past_range(Now, Window) :-
    W = duration_ns(Window),
    W > 0u64,
    Max = uint64.cast_from_int64(int64.max_int64),
    N = instant_ns(Now),
    ( N > Max
    ; W > Max - N
    ).

ntst_3_1_advance_past_range(D, C) :-
    Ns = duration_ns(D),
    Top = uint64.cast_from_int64(int64.max_int64),
    (
        Ns > Top
    ;
        C ^ c_src_wall = yes(W),
        W >= 0i64,
        Ns > Top - uint64.cast_from_int64(W)
    ;
        Ns > uint64.max_uint64 - instant_ns(C ^ c_src_mono)
    ).

clock_advance(D, C0, C) :-
    C0 ^ c_mode = mock,
    not ntst_3_1_advance_past_range(D, C0),
    C1 = C0 ^ c_src_mono := add(C0 ^ c_src_mono, D),
    Wall0 = C1 ^ c_src_wall,
    (
        Wall0 = no,
        C = C1
    ;
        Wall0 = yes(W),
        C = C1 ^ c_src_wall :=
            yes(W + int64.cast_from_uint64(duration_ns(D)))
    ).

clock_set(At, C0, C) :-
    C0 ^ c_mode = mock,
    Sampled = C0 ^ c_sampled,
    ( if Sampled = yes then
        not before(At, C0 ^ c_src_mono)
    else
        true
    ),
    C = C0 ^ c_src_mono := At.

clock_wall_set(Utc, C0, C) :-
    C0 ^ c_mode = mock,
    C = C0 ^ c_src_wall := yes(Utc).

clock_wall_unset(C0, C) :-
    C0 ^ c_mode = mock,
    C = C0 ^ c_src_wall := no.

:- type wall_reading
    --->    wall_reading(
                uint64,         % CLOCK_MONOTONIC ns, arbitrary origin
                int64           % CLOCK_REALTIME ns since the Unix epoch
            ).

read_wall_clock(wall_reading(Mono, Wall), !IO) :-
    both_clocks_ns(Mono, Wall, !IO).

    % A promise ledger entry: the read happens in `io` order and depends on
    % nothing else. One call, since [LTIM.2.8.4] samples the two together.
    %
:- pred both_clocks_ns(uint64::out, int64::out, io::di, io::uo) is det.

:- pragma foreign_decl("C", "#include <time.h>").

:- pragma foreign_proc("C",
    both_clocks_ns(Mono::out, Wall::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io],
"
    struct timespec m, w;
    clock_gettime(CLOCK_MONOTONIC, &m);
    clock_gettime(CLOCK_REALTIME, &w);
    Mono = (uint64_t) m.tv_sec * UINT64_C(1000000000) + (uint64_t) m.tv_nsec;
    Wall = (int64_t) w.tv_sec * INT64_C(1000000000) + (int64_t) w.tv_nsec;
").

clock_observe(wall_reading(Raw, Wall), C0, C) :-
    C0 ^ c_mode = live,
    C1 = C0 ^ c_src_wall := yes(Wall),
    Anchor = C1 ^ c_anchor,
    (
        Anchor = no,
        C = C1 ^ c_anchor := yes({Raw, C1 ^ c_src_mono})
    ;
        Anchor = yes({Raw0, At0}),
        ( if
            Raw > Raw0,
            Later = add(At0, duration(Raw - Raw0)),
            before(C1 ^ c_src_mono, Later)
        then
            C = C1 ^ c_src_mono := Later
        else
            C = C1
        )
    ).

%-----------------------------------------------------------------------------%
% Deadlines
%-----------------------------------------------------------------------------%

init_deadlines = deadlines([], 0).

arm(At, Client, deadlines(Es, N), deadlines([{At, N, Client} | Es], N + 1)).

due(Now, Clients, deadlines(Es, N), deadlines(Kept, N)) :-
    list.filter(entry_is_due(Now), Es, Due, Kept),
    list.sort(Due, Sorted),
    Clients = list.map(entry_client, Sorted).

next_deadline(deadlines(Es, _), At) :-
    Es = [_ | _],
    list.sort(Es, [{At, _, _} | _]).

:- pred entry_is_due(instant::in, {instant, int, Client}::in) is semidet.

entry_is_due(Now, {At, _, _}) :-
    not before(Now, At).        % At =< Now

:- func entry_client({instant, int, Client}) = Client.

entry_client({_, _, Client}) = Client.

%-----------------------------------------------------------------------------%

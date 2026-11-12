% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.cache -- the engine-side key/value cache.
%
% Its own module because `ds.exec` writes and `ds.eval` reads it.
%
% Holds no clock: each caller passes the instant it reads under. An entry is gone
% once that instant reaches its deadline ([NSTG.2.4]), on two paths, each telling
% the host with one `eff_cache_expired`:
%
%   - the pump-entry sweep, `cache_sweep`;
%   - the read, `cache_get_live`, a miss. `ds.eval` holds the cache read-only, so
%     it hands back the expired keys it read, and `ds.engine` evicts them when
%     the match is settled ([NSTG.2.4.2]). Only a host assert's matching finds
%     one: inside a pump the sweep has removed everything due.
%-----------------------------------------------------------------------------%

:- module ds.cache.
:- interface.

:- import_module ds.chrono.
:- import_module ds.value.

:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%

:- type cache.

:- func init_cache = cache.

    % A miss fails: `null` would conflate a stored `null` with a miss. Ignores
    % deadlines.
    %
:- pred cache_get(cache::in, string::in, ds_value::out) is semidet.

    % As a rule reads it: an entry whose deadline the instant has reached is a
    % miss.
    %
:- pred cache_get_live(cache::in, instant::in, string::in, ds_value::out)
    is semidet.

    % The key holds an entry whose deadline the instant has reached.
    %
:- pred cache_expired(cache::in, instant::in, string::in) is semidet.

    % Removes every entry due, and names them in the order their keys were last
    % set ([LDET.5.11]): the order the host is told in.
    %
:- pred cache_sweep(instant::in, list(string)::out, cache::in, cache::out)
    is det.

    % `Bytes`: see `cache_bytes`.
    %
:- pred cache_put(string::in, ds_value::in, int::in, maybe(instant)::in,
                  cache::in, cache::out) is det.

    % A seed made before the engine's first sample ([NLFC.9.4]): it holds its TTL
    % as a duration until `cache_resolve_held`.
    %
:- pred cache_put_held(string::in, ds_value::in, int::in, duration::in,
                       cache::in, cache::out) is det.

    % The caller has checked each deadline against the `Time` range first
    % ([NLFC.9.5]).
    %
:- pred cache_resolve_held(instant::in, cache::in, cache::out) is det.

    % The largest TTL an entry holds as a duration.
    %
:- func cache_held_ttl_max(cache) = maybe(duration).

    % [NLFC.2.5]: the earliest entry expiry later than the instant. A TTL still
    % held as a duration has no instant yet.
    %
:- func cache_next_deadline(cache, instant) = maybe(instant).

:- pred cache_delete(string::in, cache::in, cache::out) is det.

:- func cache_size(cache) = int.

    % Every entry as stored, deadlines ignored, in key order.
    %
:- func cache_entries(cache) = list({string, ds_value, maybe(instant)}).

    % [RTCT.7]'s `cache_bytes_cap`: each value's JSON encoding length in bytes,
    % quotes included, with no per-entry overhead and no key. The caller supplies
    % it at the write, since a value arrives here already interned.
    %
:- func cache_bytes(cache) = int.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module map.
:- import_module int.
:- import_module pair.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type cache
    --->    cache(
                c_entries  :: map(string, cache_entry),
                c_next_set :: int
            ).

:- type cache_entry
    --->    cache_entry(
                ce_value   :: ds_value,
                ce_bytes   :: int,
                ce_expires :: expiry,
                ce_set     :: int
                            % A write counter: when the key was last set.
            ).

:- type expiry
    --->    no_expiry
    ;       expires_at(instant)
    ;       held(duration).

init_cache = cache(map.init, 0).

cache_get(cache(M, _), Key, Value) :-
    map.search(M, Key, cache_entry(Value, _, _, _)).

cache_get_live(cache(M, _), Now, Key, Value) :-
    map.search(M, Key, Entry),
    live_at(Now, Entry),
    Value = Entry ^ ce_value.

cache_expired(cache(M, _), Now, Key) :-
    map.search(M, Key, Entry),
    not live_at(Now, Entry).

cache_sweep(Now, Expired, cache(M0, Next), cache(M, Next)) :-
    map.foldl2(sweep_entry(Now), M0, [], Stamped, M0, M),
    list.sort(Stamped, Sorted),
    Expired = list.map((func({_, K}) = K), Sorted).

:- pred sweep_entry(instant::in, string::in, cache_entry::in,
                    list({int, string})::in, list({int, string})::out,
                    map(string, cache_entry)::in, map(string, cache_entry)::out)
    is det.

sweep_entry(Now, Key, Entry, !Expired, !M) :-
    ( if live_at(Now, Entry) then
        true
    else
        map.delete(Key, !M),
        !:Expired = [{Entry ^ ce_set, Key} | !.Expired]
    ).

    % Strictly before the deadline: an entry is dropped at equality.
    %
:- pred live_at(instant::in, cache_entry::in) is semidet.

live_at(Now, Entry) :-
    Expires = Entry ^ ce_expires,
    (
        Expires = no_expiry
    ;
        Expires = held(_)
    ;
        Expires = expires_at(Deadline),
        before(Now, Deadline)
    ).

cache_put(Key, Value, Bytes, MaybeDeadline, !C) :-
    (
        MaybeDeadline = no,
        Expires = no_expiry
    ;
        MaybeDeadline = yes(Deadline),
        Expires = expires_at(Deadline)
    ),
    put_entry(Key, Value, Bytes, Expires, !C).

cache_put_held(Key, Value, Bytes, Ttl, !C) :-
    put_entry(Key, Value, Bytes, held(Ttl), !C).

:- pred put_entry(string::in, ds_value::in, int::in, expiry::in,
                  cache::in, cache::out) is det.

put_entry(Key, Value, Bytes, Expires, C0, C) :-
    C0 = cache(M0, Next),
    map.set(Key, cache_entry(Value, Bytes, Expires, Next), M0, M),
    C = cache(M, Next + 1).

cache_resolve_held(Now, cache(M0, Next), cache(M, Next)) :-
    M = map.map_values_only(resolve_entry(Now), M0).

:- func resolve_entry(instant, cache_entry) = cache_entry.

resolve_entry(Now, Entry) = Resolved :-
    Expires = Entry ^ ce_expires,
    (
        ( Expires = no_expiry
        ; Expires = expires_at(_)
        ),
        Resolved = Entry
    ;
        Expires = held(Ttl),
        Resolved = Entry ^ ce_expires := expires_at(add(Now, Ttl))
    ).

cache_held_ttl_max(cache(M, _)) =
    list.foldl(longer_held, map.values(M), no).

:- func longer_held(cache_entry, maybe(duration)) = maybe(duration).

longer_held(Entry, Max0) = Max :-
    Expires = Entry ^ ce_expires,
    (
        ( Expires = no_expiry
        ; Expires = expires_at(_)
        ),
        Max = Max0
    ;
        Expires = held(Ttl),
        ( if
            Max0 = yes(M),
            not duration_ns(Ttl) > duration_ns(M)
        then
            Max = Max0
        else
            Max = yes(Ttl)
        )
    ).

cache_next_deadline(cache(M, _), Now) =
    list.foldl(sooner_expiry(Now), map.values(M), no).

:- func sooner_expiry(instant, cache_entry, maybe(instant)) = maybe(instant).

sooner_expiry(Now, Entry, Best) = Next :-
    ( if
        Entry ^ ce_expires = expires_at(At),
        before(Now, At),
        (
            Best = no
        ;
            Best = yes(Held),
            before(At, Held)
        )
    then
        Next = yes(At)
    else
        Next = Best
    ).

cache_delete(Key, C0, C) :-
    C0 = cache(M0, Next),
    map.delete(Key, M0, M),
    C = cache(M, Next).

cache_size(cache(M, _)) = map.count(M).

cache_entries(cache(M, _)) =
    list.map((func(K - E) = {K, E ^ ce_value, stored_deadline(E ^ ce_expires)}),
        map.to_assoc_list(M)).

:- func stored_deadline(expiry) = maybe(instant).

stored_deadline(no_expiry) = no.
stored_deadline(expires_at(Deadline)) = yes(Deadline).
stored_deadline(held(_)) = no.

cache_bytes(cache(M, _)) =
    list.foldl(func(E, Acc) = Acc + E ^ ce_bytes, map.values(M), 0).

%-----------------------------------------------------------------------------%
:- end_module ds.cache.
%-----------------------------------------------------------------------------%

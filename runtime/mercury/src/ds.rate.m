% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.rate -- the cooldown gate: one window and one timestamp per key.
%
% `cooldown 30_s` lowers to a fire guard
%
%     rate_allow(<rule name>, <key value>..., cooldown_ns)
%
% whose key values [LCDB.3.3.3] selects, so this takes evaluated arguments and
% never walks a pattern. A `map` that never evicts: an evictable entry behaves as
% an absent key.
%-----------------------------------------------------------------------------%

:- module ds.rate.
:- interface.

:- import_module ds.chrono.
:- import_module ds.intern.
:- import_module ds.value.

:- import_module list.

%-----------------------------------------------------------------------------%

:- type rate_table.

:- func init_rate_table = rate_table.

:- type rate_verdict
    --->    rv_fire
    ;       rv_cool_suppress.

:- pred allows(rate_verdict::in) is semidet.

    % `Args` are the fire guard's evaluated arguments: rule name, key values, window.
    % Every abnormal shape fires: a gate that cannot decide must not suppress. Too
    % few arguments are the caller's ARTEFACT_LIED ([RDSC.4a.9.3]).
    %
:- pred rate_gate(list(ds_value)::in, intern_table::in, instant::in,
                  rate_verdict::out, rate_table::in, rate_table::out) is det.

:- type key_part.

    % The activation key, typed and whole ([IRET.25.5.3], RLOW.4.6.2.1): one part per
    % key value, by its representation ([LNUL.4.9]), compared exactly.
    %
:- func activation_key(intern_table, list(ds_value)) = list(key_part).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module bitmap.
:- import_module bool.
:- import_module ds.id.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module map.
:- import_module maybe.
:- import_module uint64.

%-----------------------------------------------------------------------------%

    % Keyed on (rule name, activation key).
    %
:- type rate_key
    --->    rate_key(string, list(key_part)).

    % The last allowed fire. A mock clock can start at 0, which is a valid instant.
    %
:- type rate_entry
    --->    rate_entry(
                re_last_fire  :: maybe(uint64)
            ).

:- type rate_table
    --->    rate_table(map(rate_key, rate_entry)).

init_rate_table = rate_table(map.init).

allows(rv_fire).

%-----------------------------------------------------------------------------%

rate_gate(Args, IT, Now, Verdict, !Table) :-
    ( if
        split_window(Args, [NameVal | KeyArgs], CoolVal),
        NameVal = str(NameRef),
        expand(IT, NameRef, RuleName)
    then
        Cool = window_ns(CoolVal),
        ( if Cool = 0u64 then
            % No window: nothing is remembered.
            Verdict = rv_fire
        else
            Key = rate_key(RuleName, activation_key(IT, KeyArgs)),
            !.Table = rate_table(Map0),
            ( if map.search(Map0, Key, Found) then
                Entry0 = Found
            else
                Entry0 = rate_entry(no)
            ),
            decide(instant_ns(Now), Cool, Entry0, Verdict, Entry),
            map.set(Key, Entry, Map0, Map),
            !:Table = rate_table(Map)
        )
    else
        Verdict = rv_fire
    ).

    % Suppress while the window since the last allowed fire has not elapsed
    % (RLOW.4.6.2); a suppressed attempt leaves the entry as it was.
    %
:- pred decide(uint64::in, uint64::in, rate_entry::in,
               rate_verdict::out, rate_entry::out) is det.

decide(Now, Cool, Entry0, Verdict, Entry) :-
    ( if
        Entry0 ^ re_last_fire = yes(Last),
        Now < Last + Cool
    then
        Verdict = rv_cool_suppress,
        Entry = Entry0
    else
        Verdict = rv_fire,
        Entry = rate_entry(yes(Now))
    ).

    % The last argument is the window.
    %
:- pred split_window(list(ds_value)::in, list(ds_value)::out,
                     ds_value::out) is semidet.

split_window(Args, Front, Cool) :-
    list.length(Args, N),
    N >= 1,
    list.split_list(N - 1, Args, Front, [Cool]).

    % A window that is not a positive integer disables the check.
    %
:- func window_ns(ds_value) = uint64.

window_ns(V) = Ns :-
    ( if V = int(I), I > 0i64 then
        Ns = uint64.cast_from_int64(I)
    else
        Ns = 0u64
    ).

%-----------------------------------------------------------------------------%
% The typed key
%-----------------------------------------------------------------------------%

    % One constructor per representation, the tag [LNUL.4.9] reads: a Time and a
    % Duration key as their counts, `str` and `text` as their content. `kp_float`
    % never holds -0.0 or NaN: `compare` on a NaN would make the map unsound.
    %
:- type key_part
    --->    kp_null
    ;       kp_int(int64)
    ;       kp_float(float)
    ;       kp_nan
    ;       kp_bool(bool)
    ;       kp_string(string)
    ;       kp_bytes(bitmap)
    ;       kp_json(json_term)
    ;       kp_fact(fact_id)
    ;       kp_ratio(int64, int64)
    ;       kp_unexpanded(intern_ref).
            % A `str` whose reference the table cannot expand.

activation_key(IT, Args) = list.map(key_part_of(IT), Args).

:- func key_part_of(intern_table, ds_value) = key_part.

key_part_of(_, int(I)) = kp_int(I).
key_part_of(_, float(F)) =
    ( if float.is_nan(F) then
        kp_nan
    else if F = 0.0 then
        kp_float(0.0)
    else
        kp_float(F)
    ).
key_part_of(IT, str(Ref)) =
    ( if expand(IT, Ref, Text) then kp_string(Text) else kp_unexpanded(Ref) ).
key_part_of(_, text(Text)) = kp_string(Text).
key_part_of(_, bool(B)) = kp_bool(B).
key_part_of(_, bytes(Bytes)) = kp_bytes(Bytes).
key_part_of(_, json(Json)) = kp_json(Json).
key_part_of(_, fact_ref(Id)) = kp_fact(Id).
key_part_of(_, duration(D)) = kp_int(int64.cast_from_uint64(duration_ns(D))).
key_part_of(_, time(T)) = kp_int(utc_ns(T)).
key_part_of(_, ratio(N, D)) = kp_ratio(N, D).
key_part_of(_, null) = kp_null.

%-----------------------------------------------------------------------------%
:- end_module ds.rate.
%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.capability -- the capability registry of [LCAP.1].
%
% `dsc.capability` imports this module. `capability_of_number` fails on a number
% it does not know, and the loader refuses that as [RDSC.16.2.7] says.
%-----------------------------------------------------------------------------%

:- module ds.capability.
:- interface.

:- import_module list.
:- import_module set.

%-----------------------------------------------------------------------------%

:- type capability
    --->    cap_realtime
    ;       cap_constspace
    ;       cap_linear_scan
    ;       cap_logical
    ;       cap_dynamic_ttl
    ;       cap_regex
    ;       cap_float
    ;       cap_call
    ;       cap_publish
    ;       cap_cache
    ;       cap_cache_delete
            % 12 is reserved.
    ;       cap_nocooldown
    ;       cap_series
    ;       cap_sampled_slots
    ;       cap_persist_on_series
            % 17, 18 and 19 are reserved.
    ;       cap_storage_hydrate_facts
    ;       cap_storage_hydrate_samples.

    % The capabilities whose setting is `true` ([RDSC.16.2.2]).
    %
:- type settings == set(capability).

    % Ascending by number.
    %
:- func all_capabilities = list(capability).

:- func capability_name(capability) = string.

:- pred capability_named(string::in, capability::out) is semidet.

:- func capability_number(capability) = int.

:- pred capability_of_number(int::in, capability::out) is semidet.

:- func ascending(settings) = list(capability).

:- func rbnd_4_2_serialization(settings) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module string.

%-----------------------------------------------------------------------------%

all_capabilities = [cap_realtime, cap_constspace, cap_linear_scan,
    cap_logical, cap_dynamic_ttl, cap_regex, cap_float, cap_call,
    cap_publish, cap_cache, cap_cache_delete, cap_nocooldown, cap_series,
    cap_sampled_slots, cap_persist_on_series, cap_storage_hydrate_facts,
    cap_storage_hydrate_samples].

capability_name(cap_realtime) = "realtime".
capability_name(cap_constspace) = "constspace".
capability_name(cap_linear_scan) = "linear_scan".
capability_name(cap_logical) = "logical".
capability_name(cap_dynamic_ttl) = "dynamic_ttl".
capability_name(cap_regex) = "regex".
capability_name(cap_float) = "float".
capability_name(cap_call) = "call".
capability_name(cap_publish) = "publish".
capability_name(cap_cache) = "cache".
capability_name(cap_cache_delete) = "cache_delete".
capability_name(cap_nocooldown) = "nocooldown".
capability_name(cap_series) = "series".
capability_name(cap_sampled_slots) = "sampled_slots".
capability_name(cap_persist_on_series) = "persist_on_series".
capability_name(cap_storage_hydrate_facts) = "storage_hydrate_facts".
capability_name(cap_storage_hydrate_samples) = "storage_hydrate_samples".

capability_named(Name, Cap) :-
    list.find_first_match((pred(C::in) is semidet :- capability_name(C) = Name),
        all_capabilities, Cap).

capability_number(cap_realtime) = 1.
capability_number(cap_constspace) = 2.
capability_number(cap_linear_scan) = 3.
capability_number(cap_logical) = 4.
capability_number(cap_dynamic_ttl) = 5.
capability_number(cap_regex) = 6.
capability_number(cap_float) = 7.
capability_number(cap_call) = 8.
capability_number(cap_publish) = 9.
capability_number(cap_cache) = 10.
capability_number(cap_cache_delete) = 11.
capability_number(cap_nocooldown) = 13.
capability_number(cap_series) = 14.
capability_number(cap_sampled_slots) = 15.
capability_number(cap_persist_on_series) = 16.
capability_number(cap_storage_hydrate_facts) = 20.
capability_number(cap_storage_hydrate_samples) = 21.

capability_of_number(N, Cap) :-
    list.find_first_match((pred(C::in) is semidet :- capability_number(C) = N),
        all_capabilities, Cap).

ascending(Settings) =
    list.filter((pred(C::in) is semidet :- set.contains(Settings, C)),
        all_capabilities).

rbnd_4_2_serialization(Settings) =
    "ds.dialect.v2\n" ++ "enabled="
        ++ string.join_list(",", list.map(capability_name, ascending(Settings)))
        ++ "\n".

%-----------------------------------------------------------------------------%
:- end_module ds.capability.
%-----------------------------------------------------------------------------%

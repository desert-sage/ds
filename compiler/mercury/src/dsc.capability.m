% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% dsc.capability -- a program's settings over [LCAP.1]'s registry, which is the
% runtime's `ds.capability`, and what the compiler alone asks of them.
%-----------------------------------------------------------------------------%

:- module dsc.capability.
:- interface.

:- import_module ds.
:- import_module ds.capability.

:- import_module list.
:- import_module map.

%-----------------------------------------------------------------------------%

    % A program's resolved settings, carried by every module of the unit
    % ([LDIA.2.10.9]). `ps_lines` holds the line that overrode a capability; one
    % with no entry has its dialect's setting.
    %
    %@helper
:- type program_settings
    --->    program_settings(
                ps_dialect :: string,
                ps_enabled :: settings,
                ps_lines   :: map(capability, int)
            ).

    % What a resolved file carries before the driver has resolved the program's
    % `use` line: every capability `false`.
    %
    %@helper
:- func unresolved_program = program_settings.

    %@helper
:- pred enabled(program_settings::in, capability::in) is semidet.

    %@helper
:- type cap_kind
    --->    strategy
    ;       construct.

    %@spec [LCAP.1]
:- func lcap_1_kind(capability) = cap_kind.

    %@spec [LCAP.3.8]
:- pred lcap_3_8_requires(capability, capability).
:- mode lcap_3_8_requires(in, out) is semidet.

    % The rows of [LCAP.3.8] a setting breaks, as (needs, needed) pairs, in
    % ascending order of the first.
    %
    %@spec [LCAP.3.8]
:- func lcap_3_8_violations(settings) = list({capability, capability}).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module set.

%-----------------------------------------------------------------------------%

unresolved_program = program_settings("", set.init, map.init).

enabled(Program, Cap) :-
    set.contains(Program ^ ps_enabled, Cap).

lcap_1_kind(cap_realtime) = strategy.
lcap_1_kind(cap_constspace) = strategy.
lcap_1_kind(cap_linear_scan) = strategy.
lcap_1_kind(cap_logical) = construct.
lcap_1_kind(cap_dynamic_ttl) = construct.
lcap_1_kind(cap_regex) = construct.
lcap_1_kind(cap_float) = construct.
lcap_1_kind(cap_call) = construct.
lcap_1_kind(cap_publish) = construct.
lcap_1_kind(cap_cache) = construct.
lcap_1_kind(cap_cache_delete) = construct.
lcap_1_kind(cap_nocooldown) = construct.
lcap_1_kind(cap_series) = construct.
lcap_1_kind(cap_sampled_slots) = construct.
lcap_1_kind(cap_persist_on_series) = construct.
lcap_1_kind(cap_storage_hydrate_facts) = construct.
lcap_1_kind(cap_storage_hydrate_samples) = construct.

lcap_3_8_requires(cap_realtime, cap_constspace).
lcap_3_8_requires(cap_storage_hydrate_facts, cap_call).
lcap_3_8_requires(cap_storage_hydrate_samples, cap_call).
lcap_3_8_requires(cap_nocooldown, cap_call).
lcap_3_8_requires(cap_persist_on_series, cap_series).

lcap_3_8_violations(Settings) = list.filter_map(
    ( func(Cap) = {Cap, Needed} is semidet :-
        set.contains(Settings, Cap),
        lcap_3_8_requires(Cap, Needed),
        not set.contains(Settings, Needed)
    ), all_capabilities).

%-----------------------------------------------------------------------------%
:- end_module dsc.capability.
%-----------------------------------------------------------------------------%

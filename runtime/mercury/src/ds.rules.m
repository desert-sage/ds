% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.rules -- the agenda order key, rule metadata, rate config.
%
% The firing order is `compare/3` on `order_key`: Mercury orders a term by its
% arguments left to right, and the fields are declared in key priority
% ([LDET.5.7.6]). The agenda is a map, so a duplicate key is detected.
%-----------------------------------------------------------------------------%

:- module ds.rules.
:- interface.

:- import_module ds.chrono.
:- import_module ds.expr.
:- import_module ds.id.
:- import_module bool.
:- import_module maybe.
:- import_module uint32.

%-----------------------------------------------------------------------------%
% The terminal ordinal
%-----------------------------------------------------------------------------%

    % A rule's index in the artefact's terminal sequence, the agenda's first key
    % [LDET.5.4, RLOW.14.3]. Read from the artefact's emission order: cross-file order
    % is import-DAG topological, and a synthesized terminal has no rule in source
    % [RLOW.14.7].
    %
:- type source_index.
:- pred source_index(int::in, source_index::out) is semidet.
:- func source_index_int(source_index) = int.

%-----------------------------------------------------------------------------%
% The order key
%-----------------------------------------------------------------------------%

    % The field order is the key priority. Refraction is no third key: a refracted
    % activation is destroyed without firing [IRET.11.3, LDET.5.3].
    %
:- type order_key
    --->    order_key(
                ok_ordinal :: source_index,     % LDET.5.4
                ok_timetag :: timetag           % LDET.5.5, within one rule
            ).

%-----------------------------------------------------------------------------%
% Rate limiting
%-----------------------------------------------------------------------------%

    % A rule's cooldown window [LCDB]. `cooldown_ns = 0` on the wire is `no`.
    %
:- type rate_config
    --->    rate_config(
                rc_cooldown :: maybe(duration)
            ).

:- func no_rate_limit = rate_config.

:- pred rate_limited(rate_config::in) is semidet.

%-----------------------------------------------------------------------------%
% Rule metadata
%-----------------------------------------------------------------------------%

    % A `TerminalNode` atom and its rule-group metadata, which arrives first: resolved
    % at the end [RDSC.8.3].
    %
:- type rule_meta
    --->    rule_meta(
                rm_terminal    :: node_id,
                rm_name        :: intern_ref,
                rm_source      :: source_index,
                rm_rate        :: rate_config,

                rm_fire_guard  :: maybe(expr),
                            % evaluated once per firing

                rm_display     :: maybe(string),
                            % `RuleDebugName` template [RDSC.6.8.4]

                rm_where       :: maybe(source_pos)
                            % `RuleSource` [RDSC.6.7]
            ).

    % A position in a module's DS source: 1-based line and column, and the module's
    % `module_id`.
    %
:- type source_pos
    --->    source_pos(
                sp_line :: uint32,
                sp_col  :: uint32,
                sp_clip :: uint32
            ).

:- func order_key_of(rule_meta, timetag) = order_key.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.

%-----------------------------------------------------------------------------%

:- type source_index ---> source_index(int).

source_index(N, source_index(N)) :-
    N >= 0.

source_index_int(source_index(N)) = N.

%-----------------------------------------------------------------------------%

no_rate_limit = rate_config(no).

rate_limited(rate_config(yes(_))).

%-----------------------------------------------------------------------------%

order_key_of(Meta, TT) = order_key(Meta ^ rm_source, TT).

%-----------------------------------------------------------------------------%

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.token -- tokens and activations.
%-----------------------------------------------------------------------------%

:- module ds.token.
:- interface.

:- import_module ds.id.
:- import_module list.

%-----------------------------------------------------------------------------%

    % A partial or complete match: position i is the fact bound by the rule's i-th
    % positive pattern.
    %
:- type token
    --->    token(
                t_facts   :: list(fact_id),
                t_created :: timetag
            ).

    % The seed token of a root beta [RDSC.4a.7].
    %
:- func nil_token(timetag) = token.

:- func token_width(token) = int.

%-----------------------------------------------------------------------------%

    % A completed match awaiting firing. The order key is derived
    % (`ds.rules.order_key_of`).
    %
:- type activation
    --->    activation(
                ac_terminal :: node_id,
                ac_token    :: token
            ).

:- func activation_timetag(activation) = timetag.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.

nil_token(TT) = token([], TT).

token_width(token(Facts, _)) = list.length(Facts).

activation_timetag(activation(_, token(_, TT))) = TT.

%-----------------------------------------------------------------------------%

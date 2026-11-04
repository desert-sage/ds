%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.host.m.
%
% What passes between a session and its host: the duties a pump hands the
% host, and the answer a host gives a rule's `call`. No sample duty and no
% series declarations: there is no samples plane, and NSTG.5 is deferred.
%
% A session performs nothing. A pump returns, as data, the duties its
% firings produced and the calls they issued; the host performs the duties
% in the order given and answers each call back into the session
% (`mercury_ds.session.answer`). Nothing a host does runs inside a call to
% the session, so the session a call returns is the whole of what it did,
% and copying a session copies no host: a clone starts with none
% ([NLFC.8.3]).
%
%---------------------------------------------------------------------------%

:- module mercury_ds.host.
:- interface.

:- import_module mercury_ds.events.
:- import_module mercury_ds.value.
:- import_module list.

%---------------------------------------------------------------------------%
% Services
%---------------------------------------------------------------------------%

    % What a service did with a call.
    %
:- type service_answer
    --->    answered(list(storable))
            % The response: every slot of the service's response schema but
            % `corr`, in declaration order. The binding sets `corr` to the
            % call's correlation.
    ;       no_response
            % Done, for a service declared `no response`.
    ;       call_error(string, string)
            % It could not be done: the `CallError`'s code and message.
    ;       not_offered.
            % The host offers no service of this name.

%---------------------------------------------------------------------------%
% Duties
%---------------------------------------------------------------------------%

    % Something a call asks of the host, which the engine does not do itself:
    % libds hands each to a callback. Every call that changes a session but a
    % replay hands them over.
    %
:- type duty
    --->    write_cache(cache_write)
            % A rule's `cache` wrote a key: write it through to the host's
            % store.
    ;       remove_cache(cache_removal).
            % A key left the engine's cache: remove it from the store.

    % A key leaving the engine's cache.
    %
:- type cache_removal
    --->    cache_removal(
                cache_removal_key    :: string,
                cache_removal_reason :: removal_reason
            ).

:- type removal_reason
    --->    removed_by_rule
            % A rule's `cache_delete`.
    ;       expired.
            % The entry's TTL ran out.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.error.m.
%
% What a call that failed answers with. A failure is a value, as
% `io.res` is (MER.8): libds's status for the same case and a detail for a
% person.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.error.
:- interface.

:- import_module mercury_ds.status.

%---------------------------------------------------------------------------%

    % Why a call failed.
    %
:- type ds_error
    --->    status_error(status, string).
            % The status libds answers for the same case, never `ok`, and a
            % detail for a person. No program should parse the detail.

    % The status an error carries.
    %
:- pred error_status(ds_error::in, status::out) is det.

    % What a call with nothing else to return did: `ok`, or the error, as
    % `io.res` is for a library call. Named `outcome` rather than `res`,
    % which `io` exports.
    %
:- type outcome
    --->    ok
    ;       error(ds_error).

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

error_status(status_error(Status, _), Status).

%---------------------------------------------------------------------------%

%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% dsc.builtin_types -- GENERATED. Do not edit: regenerate it.
%
% [LGRA.22.8]'s builtin types, one constructor per row of the clause's `data` table.
%
% 10 rows; sha256 (first 16) of the rows as JSON: e6fbe8f7ebe6bb1d.
%-----------------------------------------------------------------------------%

:- module dsc.builtin_types.
:- interface.

:- import_module list.

    %@spec [LGRA.22.8]
:- type lgra_22_8_builtin_type
    --->    bt_bool       % [LGRA.5.1]
    ;       bt_bytes      % [LGRA.5.1]
    ;       bt_date       % [LTIM.1]
    ;       bt_duration   % [LTIM.1]
    ;       bt_float      % [LGRA.5.1]
    ;       bt_int        % [LGRA.5.1]
    ;       bt_interval   % [LINT.1]
    ;       bt_json       % [LGRA.5.8]
    ;       bt_string     % [LGRA.5.1]
    ;       bt_time.      % [LTIM.1]

    % In the clause's order.
    %
    %@spec [LGRA.22.8]
:- func lgra_22_8_builtin_types = list(lgra_22_8_builtin_type).

    %@spec [LGRA.22.8]
:- func lgra_22_8_type_name(lgra_22_8_builtin_type) = string.

    %@spec [LGRA.22.8]
:- pred lgra_22_8_named(string::in, lgra_22_8_builtin_type::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

lgra_22_8_builtin_types =
    [bt_bool,
     bt_bytes,
     bt_date,
     bt_duration,
     bt_float,
     bt_int,
     bt_interval,
     bt_json,
     bt_string,
     bt_time].

lgra_22_8_type_name(bt_bool) = "Bool".
lgra_22_8_type_name(bt_bytes) = "Bytes".
lgra_22_8_type_name(bt_date) = "Date".
lgra_22_8_type_name(bt_duration) = "Duration".
lgra_22_8_type_name(bt_float) = "Float".
lgra_22_8_type_name(bt_int) = "Int".
lgra_22_8_type_name(bt_interval) = "Interval".
lgra_22_8_type_name(bt_json) = "Json".
lgra_22_8_type_name(bt_string) = "String".
lgra_22_8_type_name(bt_time) = "Time".

lgra_22_8_named("Bool", bt_bool).
lgra_22_8_named("Bytes", bt_bytes).
lgra_22_8_named("Date", bt_date).
lgra_22_8_named("Duration", bt_duration).
lgra_22_8_named("Float", bt_float).
lgra_22_8_named("Int", bt_int).
lgra_22_8_named("Interval", bt_interval).
lgra_22_8_named("Json", bt_json).
lgra_22_8_named("String", bt_string).
lgra_22_8_named("Time", bt_time).

%-----------------------------------------------------------------------------%
:- end_module dsc.builtin_types.
%-----------------------------------------------------------------------------%

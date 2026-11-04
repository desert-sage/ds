%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% ds.names -- GENERATED. Do not edit: change the definition and
% regenerate ([STYL.5.9.6]).
%
% The names runtime/src/bindings/ds_names.h gives libds's enums, given to
% this runtime's own types, for a host or a trace that writes one as text.
% From:
%   proto/log_level.proto
%   specs/registry/metric_kind.ebnf
%   specs/registry/series_storage_mode.ebnf
%   proto/series_backend_ring_buffer.proto
%
% ONE CLAUSE PER CONSTRUCTOR. Each function is det, so a constructor no
% member names, or a member whose constructor the type lacks, does not
% compile. A member a type leaves out on purpose is in the generator's
% NO_CONSTRUCTOR, with its reason ([STYL.5.9.6]).
%-----------------------------------------------------------------------------%

:- module ds.names.
:- interface.

:- import_module ds.action.
:- import_module ds.events.
:- import_module ds.series.

    % proto/log_level.proto#LogSeverity (NCBK.4.5).
    %
    %@helper
:- func log_level_name(log_level) = string.

    % specs/registry/metric_kind.ebnf (NMET.3.4).
    %
    %@helper
:- func metric_kind_name(metric_kind) = string.

    % specs/registry/series_storage_mode.ebnf (NSTG.5.5.4).
    %
    %@helper
:- func storage_mode_name(storage_mode) = string.

    % proto/series_backend_ring_buffer.proto#SeriesElementType (NSBK.5.3).
    %
    %@helper
:- func element_type_name(element_type) = string.

%-----------------------------------------------------------------------------%

:- implementation.

log_level_name(log_debug) = "DEBUG".
log_level_name(log_info) = "INFO".
log_level_name(log_warning) = "WARNING".
log_level_name(log_error) = "ERROR".
log_level_name(log_critical) = "CRITICAL".

metric_kind_name(mk_counter) = "counter".
metric_kind_name(mk_gauge) = "gauge".

storage_mode_name(sm_accumulator) = "accumulator".
storage_mode_name(sm_ring_buffer) = "ring_buffer".

element_type_name(el_unspecified) = "unknown".
element_type_name(el_float) = "Float".
element_type_name(el_int) = "Int".
element_type_name(el_string) = "String".
element_type_name(el_bool) = "Bool".

%-----------------------------------------------------------------------------%
:- end_module ds.names.
%-----------------------------------------------------------------------------%

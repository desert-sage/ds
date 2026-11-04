%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.m.
%
% The Mercury DS runtime, bound into Mercury programs: an integrator's
% surface over `runtime/mercury`, as `libds.h` is over libds.
%
%   mercury_ds.session     load; assert, retract, pump, answer; the clock
%   mercury_ds.host        what passes to the host and back: duties, answers
%   mercury_ds.events      what a call reports: events, log lines, metrics
%   mercury_ds.introspect  rules, source, justifiers, the artefact
%   mercury_ds.atoms       the atoms of an artefact or a recording
%   mercury_ds.value       the values a host asserts and reads
%   mercury_ds.error       a failure, as a value
%   mercury_ds.status      the status codes, generated from status.proto
%
% It uses the runtime's own types wherever the runtime has one, and adds no
% foreign code and no purity promise (MER.6).
%
% So a host names the runtime's types as well, and imports the runtime
% module that defines each one it names:
%
%   ds.chrono          instant, duration: the clock, a TTL
%   ds.id              fact_id, timetag, seq, node_id
%   ds.value           ds_value, of which `storable` is the subtype a slot
%                      holds; json_term, its name for a `Json` value
%   ds.json            json, a `Json` value and a cache seed
%   ds.schema          schema, a schema the session holds
%   ds.engine          engine; fire_budget; engine_mem, trace_step and
%                      refracted_activation, what the engine reports of
%                      itself
%   ds.dsc             program, dsc_header, ds_source, line_span; admission,
%                      admission_policy; svcd, a service's declaration
%                      ([NDBG.2.4])
%   ds.service         service_kwarg and kwarg_default, one declared kwarg
%   ds.capability      capability, what an admission policy admits
%   ds.events         metric and metric_kind, a report's; stream_event, a
%                      recording's
%   ds.action          log_level, a log line's
%   ds.fact_external   arg and arg_value, a call's arguments; fact_external, a
%                      publish
%   ds.network         network, what the introspection reads walk
%   ds.fault           engine_error, why a session halted
%   ds.atom            atom_ref and atom_id, an atom's identity
%   ds.rfcs            stream_meta, the session header
%
% A host imports these and `mercury_ds`'s modules alike. Where a call here
% has the name of one in `ds.engine` (`advance`, `set_clock`,
% `set_wall_clock`, `run_id`, `tier_id`, `session_header`), it does to a
% session what that does to an engine, and Mercury tells the two apart by
% their arguments' types (MER.3).
%
%---------------------------------------------------------------------------%

:- module mercury_ds.
:- interface.

:- include_module atoms.
:- include_module error.
:- include_module events.
:- include_module host.
:- include_module introspect.
:- include_module session.
:- include_module status.
:- include_module value.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

    % Private: what the runtime's values become for a host, shared by the
    % modules above and imported by no host.
    %
:- include_module from_runtime.

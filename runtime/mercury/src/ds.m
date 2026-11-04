%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% Mercury implementation of the DS runtime.
%
% ds.m -- library root. Consumes compiled `.dsc` artefacts; parses no DS source.
% Modules are listed type layer first.
%-----------------------------------------------------------------------------%

:- module ds.
:- interface.

% -- The type layer -----------------------------------------------------------

:- include_module id.        % opaque identifiers
:- include_module json.      % the Json term
:- include_module json_text. % Json text to a term
:- include_module i64.       % DS Int is int64
:- include_module value.     % ds_value
:- include_module kind.      % GENERATED: fact_external.proto#Kind
:- include_module chrono.    % instants, durations, the clock, one deadline heap
:- include_module schema.    % slot kinds, identity roles, lifecycles
:- include_module fact.      % facts, working-memory entries, identity projection
:- include_module fault.     % faults, load errors, and each error's disposition
:- include_module builtins.  % the BuiltinFn enum
:- include_module expr.      % the expression tree
:- include_module token.     % tokens, activations, the timetag
:- include_module rules.     % bands, the order key, rule metadata, rate config
:- include_module action.    % the RHS verbs
:- include_module events.    % stream events and the effect list
:- include_module wire.      % varints, tags, length-delimited slices
:- include_module fact_external. % Arg and FactExternal, the portable typed value
:- include_module atom.      % the atom registry and the frame walk
:- include_module effect.    % ordered emission, firing frames, seq
:- include_module rfcs.      % the recorded stream's codec
:- include_module sha256.    % the artefact binding hash
:- include_module capability. % [LCAP.1]'s registry, shared with the compiler
:- include_module binding.   % the two binding comparators
:- include_module contract.  % the RealtimeContract body
:- include_module series.    % the series backings
:- include_module network.   % alpha/beta/terminal nodes, and their resolution
:- include_module service.   % a service's kwargs, ServiceDef's shape, shared with the compiler
:- include_module dsc.       % the staged, atomic artefact loader
:- include_module dsc_schema. % SchemaDef/Slot/SchemaLogical/SchemaTtl bodies -> schemas
:- include_module dsc_judge. % a network body judged for its decode before it is read (RDSC.11.4)
:- include_module dsc_expr.  % the expression tree's decoder
:- include_module dsc_action. % TerminalNode-inline actions (term.proto Action)
:- include_module dsc_network. % AlphaNode/BetaNode/TerminalNode bodies -> a resolved network
:- include_module dsc_rules. % RuleCooldown/RuleSource/RuleDebugName -> rule_meta
:- include_module intern.    % the string intern table
:- include_module version.   % GENERATED (scripts/build/gen_version_module.py): this build's DS version
:- include_module ds_validate. % GENERATED from specs/registry/validate.ebnf ([RCLI.5.1])
:- include_module names.     % GENERATED: ds_names.h's names, for these types
:- include_module event_kind. % GENERATED: a stream event's kind, and its name
:- include_module re2.       % RE2, the regex language; foreign
:- include_module float_text. % Float text; foreign
:- include_module core_math. % the transcendentals; foreign
:- include_module platform.  % the platform signature's build facts; foreign

% -- Behaviour -----------------------------------------------------------------

:- include_module wm.        % working memory: identity, dedup, the TTL sweep
:- include_module cache.     % the engine-side k/v cache
:- include_module format.    % interpolation primitives and the canonical texts
:- include_module eval.      % the evaluator
:- include_module match.     % alpha dispatch, beta joins, NOT nodes
:- include_module agenda.    % conflict resolution
:- include_module tms.       % truth maintenance
:- include_module rate.      % the cooldown gate
:- include_module exec.      % firing a terminal
:- include_module engine.    % the pump
:- include_module fact_receive. % a FactExternal from another tier, asserted
:- include_module replay.    % a decoded recording back through a fresh engine

% -- The TMS obligation check ----------------------------------------------------------------

:- include_module conform.   % formal-layer properties, executable

% `rule` is a Mercury operator, `event` is reserved, `error` is a stdlib module,
% and `time` shadows one: hence rules, events, fault and chrono.

:- implementation.

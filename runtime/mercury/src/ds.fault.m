% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.fault -- faults, load errors, and what each one does to the engine.
%
% `latched` is the halt ([LERR.1] rung 7, [NCBK.2.9]): an `EngineError` stops the
% tier and the latch never clears. Every engine-class fault reaches it through
% `disposition/1`.
%-----------------------------------------------------------------------------%

:- module ds.fault.
:- interface.

:- import_module bool.
:- import_module ds.id.
:- import_module ds.json.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% Clause citations
%-----------------------------------------------------------------------------%

    % A spec clause id, e.g. `RDSC.8.7`.
    %
:- type clause_id.

    % Checks the shape only: an uppercase prefix and dot-separated alphanumeric
    % components.
    %
:- pred clause_id(string::in, clause_id::out) is semidet.

:- func clause_id_string(clause_id) = string.

%-----------------------------------------------------------------------------%
% Hard runtime faults
%-----------------------------------------------------------------------------%

    % A fault raised while evaluating an expression. It abandons the evaluation,
    % and `??` does not rescue it.
    %
    % In an action it abandons the activation [LERR.1] (`ds.exec.abandon`). In a
    % `where` or a join test it declines the match, and one is recorded per test
    % list, the one [LNUL.4.2] selects, and none when a test is `false`
    % ([IRET.7.6], [LERR.1.4.11]).
    %
:- type runtime_fault
    --->    rf_type_mismatch
            % Not yet classified: `ds.eval.eval` turns it into one of the two
            % below at the node that raised it.

    ;       rf_type_error
            % `TypeError`: raised by a node whose value derives from a `Json`
            % projection.

    ;       rf_artefact_lied
            % `EngineError` / `ENGINE_FAULT_ARTEFACT_LIED`: raised by a clean node.

    ;       rf_pattern_index
            % `EngineError` / `ENGINE_FAULT_PATTERN_INDEX`: a read of a token
            % position the match never bound.

    ;       rf_binding_order
            % `EngineError` / `ENGINE_FAULT_BINDING_ORDER`: a `let` read before its
            % binding action ran.

    ;       rf_unimplemented
            % An expression this runtime cannot evaluate. `ds.dsc` refuses such a
            % bundle first. Recorded as EngineError where it is raised.

    ;       rf_div_zero
    ;       rf_mod_zero

    ;       rf_domain
            % `ComputationError` DOMAIN: `sqrt` of a negative [LERR.1.4.9], a shift
            % by a negative count [LEXP.7.14.1].

    ;       rf_not_representable
            % `ComputationError` NOT_REPRESENTABLE: a currency rounding whose exact
            % answer has no `Int64` [LUNI.13.10], or a finite `Float :: Int` whose
            % truncation has none ([LERR.1.4.9]).

    ;       rf_time_range
            % A `Time` left the representable range [LTIM.1.1.5].

    ;       rf_cast_non_finite(float).
            % `Float :: Int` where the operand is NaN or an infinity. Carries the
            % operand.

%-----------------------------------------------------------------------------%
% Load errors
%-----------------------------------------------------------------------------%

    % Why an artefact was refused (RDSC.9.8).
    %
:- type load_error
    --->    load_error(
                le_kind   :: load_error_kind,
                le_offset :: maybe(int),
                            % Byte offset into the artefact [RDSC.11.2]; `no` for
                            % an error found in the post-stream resolution sweep.

                le_atom   :: maybe(string),
                            % The atom's message name, e.g. "BetaNode"; `no` where
                            % the failure precedes atom identification.

                le_clause :: clause_id,

                le_reason :: maybe(string)
                            % [RDSC.9.5]: the decoder's reason for a body that
                            % fails to decode.
            ).

:- type load_error_kind
    --->    lek_truncated           % DS_ERR_DSC_TRUNCATED
    ;       lek_version             % DS_ERR_DSC_VERSION
    ;       lek_decode              % DS_ERR_DSC_DECODE
    ;       lek_semantic            % DS_ERR_DSC_SEMANTIC
            % No duplicate-atom kind: a runtime checks for no second atom
            % ([RDSC.7.2]).
    ;       lek_dangling           % DS_ERR_DSC_DANGLING -- RDSC.8.7's names
    ;       lek_decompress          % DS_ERR_DSC_DECOMPRESS; COMPRESSION_NONE only

    ;       lek_bad_first_atom
            % DS_ERR_DSC_BAD_MAGIC: the first atom is neither container's
            % [RFCS.19.4], [RDSC.11.1].

    ;       lek_empty_atom
            % An `Atom` with no `oneof` member set [RFCS.19.3], which protobuf
            % accepts silently.

    ;       lek_malformed_field_number
            % DS_ERR_DSC_DECODE: a later frame whose field number has no
            % registry entry, and so names no member of `Atom`'s oneof
            % [RDSC.11.1], [RFCS.19.3].

            % No kind for a missing network: an artefact with no rule network
            % loads ([RDSC.4a.2]).
    ;       lek_retp_invalid
    ;       lek_retp_index_oob      % a node_id naming no node, RDSC.11.1

    ;       lek_pir_type            % nothing raises it
            % No arity kind: the engine counts a call's operands on evaluation
            % ([RDSC.4a.9.3], `ds.eval`).
    ;       lek_pir_tms             % nothing raises it

    ;       lek_binding_mismatch
            % Element-wise and fail-closed [RBND.1.5].

    ;       lek_capability_absent(int)
            % DS_ERR_DSC_CAPABILITY_ABSENT [RDSC.16.2.7]: carries the lowest
            % capability number this build has no code for or does not know.

    ;       lek_not_admitted(int, bool)
            % DS_ERR_BND_DIALECT_MISMATCH [NLFC.10.2]: carries the lowest capability
            % the admission policy refuses, and the artefact's setting.

    ;       lek_contract_missing    % realtime with no RealtimeContract
    ;       lek_contract_invalid    % RealtimeContract decode, or recomputed hash disagrees

    ;       lek_contract_breach(cap)
            % The artefact's own strings exceed `intern_cap` or `intern_bytes_cap`,
            % interned as it loads.

    ;       lek_no_portable_ir      % nothing raises it

    ;       lek_binding_incomplete
            % DS_ERR_BND_INCOMPLETE [RDSC.3.7]: `dialect_def_sha256` is not 32 bytes.

    ;       lek_fn_not_found.
            % DS_ERR_FN_NOT_FOUND [RDSC.4a.9.3]: a `CallExpr` names a builtin this
            % runtime has no handler for.

%-----------------------------------------------------------------------------%
% Engine errors and what they do
%-----------------------------------------------------------------------------%

    % A failure arising once the engine is running.
    %
:- type engine_error
    --->    ee_expr_fault(runtime_fault)

    ;       ee_contract_breach(cap)
            % A cap was exceeded: the operation does not happen and the engine
            % carries on.

            % No recorder failure: the call that fired a failing sink returns its
            % status ([NCBK.1.5]), and `EngineFault` 5 is reserved.

    ;       ee_fire_budget_exceeded(int)
            % The per-pump firing budget, a pause: survivors stay queued for the
            % next pump. `run_to_quiescence` needs it to be `det`.
    ;       ee_slot_invalid(int, slot_reason)
            % A slot value the schema does not admit: carries the slot index and
            % why. The fact does not enter, and the firing's earlier actions stand.

    ;       ee_duplicate_order_key
            % Two activations claimed one agenda order key [RARC.5.4.9].

    ;       ee_internal.
            % libds found its own invariant broken [IERR.1.7]. This runtime has
            % no intern counts and never raises it.

    % Which rule a refused slot value broke:
    %
    %   sr_kind_mismatch      [RARC.5.2.6]
    %   sr_null_non_nullable  [LNUL.3.1]; a `Json` document whose root is null is
    %                         that `null` [LNUL.3.4]
    %   sr_nan_rejected       [LEXP.4.2]
    %   sr_json_limit(B)      [LGRA.5.8.6]: at a host assert, the status alone
    %   sr_json_nonfinite     [LGRA.5.8.10]: at a host assert, the status alone. A
    %                         rule never reaches it ([LDET.3.2.7])
    %
:- type slot_reason
    --->    sr_kind_mismatch
    ;       sr_null_non_nullable
    ;       sr_nan_rejected
    ;       sr_json_nonfinite
    ;       sr_json_limit(json_breach).

:- type cap
    --->    cap_wm_max
    ;       cap_agenda
    ;       cap_max_fires_per_pump
    ;       cap_token_pool
    ;       cap_intern
    ;       cap_intern_bytes
    ;       cap_pump_wcet
    ;       cap_node(node_id)
    ;       cap_series
    ;       cap_cache
    ;       cap_cache_bytes
    ;       cap_value_capacity.
            % [LSTR.11.3]: the slot's own bound, binding with no contract.

    % What an error does to the engine.
    %
:- type failure_disposition
    --->    rejected
            % The operation did not happen; engine state is unchanged.

    ;       reported
            % It happened: a record enters the stream and the session continues.

    ;       latched.
            % The tier halts for good ([LERR.1] rung 7, [NCBK.2.9]).

:- func disposition(engine_error) = failure_disposition.

    % Which record describes an error. Not derivable from `disposition/1`: a
    % contract breach and a slot refusal are both `rejected`, yet the first is a
    % BoundsError and the second a ComputationError.
    %
:- type fault_class
    --->    fc_computation      % ComputationError 325
    ;       fc_bounds           % BoundsError 329
    ;       fc_type             % TypeError 328
    ;       fc_engine.          % EngineError 330: halts the tier

:- func fault_class(engine_error) = fault_class.

    % A type mismatch splits by provenance ([LERR.1]).
    %
:- func expr_fault_class(runtime_fault) = fault_class.

    % The `TrapKind` a `ComputationError` records (`proto/engine_error.proto`),
    % and 0 for a fault of any other class.
    %
:- func expr_trap_kind(runtime_fault) = uint32.

    % The `EngineFault` an `EngineError` records (`proto/engine_fault.proto`),
    % and 0 for a fault of any other class.
    %
:- func expr_engine_fault(runtime_fault) = uint32.

    % [LNUL.4.2]'s order among faults, the kind half: `EngineError`, then
    % `TypeError`, then the trap kinds, lower first. `ds.eval.lnul_4_2_before`
    % compares this and the rest of the record together; nothing selects on this
    % key alone.
    %
:- func lnul_4_2_kind_key(runtime_fault) = int.

    % The two built-in fault schemas ([LERR.9.4]). Only the engine asserts their
    % facts ([LSCP.2.6.1]), so they are derived wherever they are met.
    %
:- pred lerr_9_4_fault_schema_name(string::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

lerr_9_4_fault_schema_name("ComputationError").
lerr_9_4_fault_schema_name("TypeError").

:- import_module char.
:- import_module int.
:- import_module list.
:- import_module string.
:- import_module uint32.

%-----------------------------------------------------------------------------%

:- type clause_id ---> clause_id(string).

clause_id(S, clause_id(S)) :-
    Components = string.split_at_char('.', S),
    Components = [Prefix | Rest],
    Rest = [_ | _],
    string.all_match(char.is_upper, Prefix),
    Prefix \= "",
    list.all_true(nonempty_alnum, Rest).

    % Alphanumeric: the corpus has `RDSC.4a.3`.
    %
:- pred nonempty_alnum(string::in) is semidet.

nonempty_alnum(S) :-
    S \= "",
    string.all_match(char.is_alnum, S).

clause_id_string(clause_id(S)) = S.

%-----------------------------------------------------------------------------%

disposition(ee_expr_fault(Fault)) =
    ( if expr_fault_class(Fault) = fc_engine then latched else reported ).
disposition(ee_contract_breach(_)) = rejected.
disposition(ee_slot_invalid(_, _)) = rejected.
disposition(ee_fire_budget_exceeded(_)) = reported.
disposition(ee_duplicate_order_key) = latched.
disposition(ee_internal) = latched.

fault_class(ee_expr_fault(Fault))      = expr_fault_class(Fault).
fault_class(ee_slot_invalid(_, _))     = fc_computation.
fault_class(ee_contract_breach(_))     = fc_bounds.
fault_class(ee_fire_budget_exceeded(_)) = fc_bounds.
fault_class(ee_duplicate_order_key)    = fc_engine.
fault_class(ee_internal)               = fc_engine.

expr_fault_class(rf_type_error)          = fc_type.
expr_fault_class(rf_artefact_lied)       = fc_engine.
expr_fault_class(rf_type_mismatch)       = fc_engine.
expr_fault_class(rf_pattern_index)       = fc_engine.
expr_fault_class(rf_binding_order)       = fc_engine.
expr_fault_class(rf_unimplemented)       = fc_engine.
expr_fault_class(rf_div_zero)            = fc_computation.
expr_fault_class(rf_mod_zero)            = fc_computation.
expr_fault_class(rf_domain)              = fc_computation.
expr_fault_class(rf_not_representable)   = fc_computation.
expr_fault_class(rf_time_range)         = fc_computation.
expr_fault_class(rf_cast_non_finite(_))  = fc_computation.

expr_trap_kind(rf_div_zero) = 1u32.
expr_trap_kind(rf_mod_zero) = 1u32.
expr_trap_kind(rf_domain) = 2u32.
expr_trap_kind(rf_not_representable) = 3u32.
expr_trap_kind(rf_time_range) = 3u32.
expr_trap_kind(rf_cast_non_finite(_)) = 3u32.
expr_trap_kind(rf_type_mismatch) = 0u32.
expr_trap_kind(rf_type_error) = 0u32.
expr_trap_kind(rf_artefact_lied) = 0u32.
expr_trap_kind(rf_pattern_index) = 0u32.
expr_trap_kind(rf_binding_order) = 0u32.
expr_trap_kind(rf_unimplemented) = 0u32.

expr_engine_fault(rf_artefact_lied)      = 1u32.
expr_engine_fault(rf_type_mismatch)      = 1u32.
expr_engine_fault(rf_pattern_index)      = 2u32.
expr_engine_fault(rf_binding_order)      = 3u32.
% `engine_fault.proto` has no member for it: ENGINE_FAULT_UNSPECIFIED.
expr_engine_fault(rf_unimplemented)      = 0u32.
expr_engine_fault(rf_type_error)         = 0u32.
expr_engine_fault(rf_div_zero)           = 0u32.
expr_engine_fault(rf_mod_zero)           = 0u32.
expr_engine_fault(rf_time_range)         = 0u32.
expr_engine_fault(rf_cast_non_finite(_)) = 0u32.
expr_engine_fault(rf_domain)             = 0u32.
expr_engine_fault(rf_not_representable)  = 0u32.

    % The class decides the hundreds, the `EngineFault` or `TrapKind` the rest.
lnul_4_2_kind_key(F) = Key :-
    Class = expr_fault_class(F),
    (
        Class = fc_engine,
        Key = 0 + uint32.cast_to_int(expr_engine_fault(F))
    ;
        Class = fc_type,
        Key = 100
    ;
        Class = fc_computation,
        Key = 200 + uint32.cast_to_int(expr_trap_kind(F))
    ;
        % An expression fault is never a BoundsError.
        Class = fc_bounds,
        Key = 300
    ).

%-----------------------------------------------------------------------------%

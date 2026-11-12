%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.status.m.
%
% GENERATED from
% proto/status.proto. Do
% not edit it: the mercury gate runs the generator's --check, so a
% hand edit is a red build.
%
% The status codes a DS call answers with, as a closed type. A code's
% number is its identity, and the same in every runtime and binding; its
% name is a label.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.status.
:- interface.

    % A status code: `ok` for success, and one constructor for each
    % failure.
    %
:- type status
    --->    ok
    ;       inval
    ;       oom
    ;       not_found
    ;       state
    ;       overflow
    ;       unsupported
    ;       internal
    ;       io
    ;       engine_halted
    ;       parse
    ;       schema_unknown
    ;       slot_unknown
    ;       slot_type_mismatch
    ;       fact_invalid
    ;       action_failed
    ;       time_range
    ;       nan_rejected
    ;       json_nonfinite
    ;       series_no_backing
    ;       schema_hash_mismatch
    ;       fact_ref_conflict
    ;       json_limit
    ;       encoding
    ;       not_representable
    ;       storage_unavailable
    ;       storage_query_failed
    ;       storage_not_found
    ;       dsc_truncated
    ;       dsc_bad_magic
    ;       dsc_version
    ;       dsc_decode
    ;       dsc_semantic
    ;       dsc_dangling
    ;       dsc_decompress
    ;       dsc_capability_absent
    ;       retp_invalid
    ;       retp_index_oob
    ;       fn_not_found
    ;       budget_exceeded
    ;       wm_full
    ;       token_budget
    ;       rt_unsafe
    ;       rt_live
    ;       rt_precond
    ;       backend_abi_version
    ;       backend_bad_magic
    ;       backend_bad_aggs
    ;       backend_not_registered
    ;       bnd_dsc_mismatch
    ;       bnd_dialect_mismatch
    ;       bnd_incomplete
    ;       bnd_rt_config_mismatch
    ;       contract_breach
    ;       contract_missing
    ;       contract_invalid
    ;       rtct_profile_refuses_dsrt
    ;       contract_wcet_halt
    ;       fs_version
    ;       fs_divergence
    ;       fs_recording_incomplete
    ;       fs_unknown_fact_id.

    % The code's number, as proto/status.proto and libds.h give it.
    %
:- func status_number(status) = int.

    % The code a number names. Fail if no live code has that number.
    %
:- pred number_status(int::in, status::out) is semidet.

    % The code's name, as libds.h spells it.
    %
:- func status_name(status) = string.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

status_number(ok) = 0.
status_number(inval) = -1.
status_number(oom) = -2.
status_number(not_found) = -3.
status_number(state) = -4.
status_number(overflow) = -5.
status_number(unsupported) = -7.
status_number(internal) = -8.
status_number(io) = -9.
status_number(engine_halted) = -10.
status_number(parse) = -100.
status_number(schema_unknown) = -101.
status_number(slot_unknown) = -103.
status_number(slot_type_mismatch) = -104.
status_number(fact_invalid) = -200.
status_number(action_failed) = -202.
status_number(time_range) = -205.
status_number(nan_rejected) = -216.
status_number(json_nonfinite) = -217.
status_number(series_no_backing) = -218.
status_number(schema_hash_mismatch) = -219.
status_number(fact_ref_conflict) = -220.
status_number(json_limit) = -221.
status_number(encoding) = -222.
status_number(not_representable) = -223.
status_number(storage_unavailable) = -400.
status_number(storage_query_failed) = -401.
status_number(storage_not_found) = -402.
status_number(dsc_truncated) = -500.
status_number(dsc_bad_magic) = -501.
status_number(dsc_version) = -502.
status_number(dsc_decode) = -503.
status_number(dsc_semantic) = -504.
status_number(dsc_dangling) = -506.
status_number(dsc_decompress) = -507.
status_number(dsc_capability_absent) = -514.
status_number(retp_invalid) = -601.
status_number(retp_index_oob) = -602.
status_number(fn_not_found) = -604.
status_number(budget_exceeded) = -605.
status_number(wm_full) = -606.
status_number(token_budget) = -607.
status_number(rt_unsafe) = -608.
status_number(rt_live) = -609.
status_number(rt_precond) = -610.
status_number(backend_abi_version) = -620.
status_number(backend_bad_magic) = -621.
status_number(backend_bad_aggs) = -622.
status_number(backend_not_registered) = -623.
status_number(bnd_dsc_mismatch) = -700.
status_number(bnd_dialect_mismatch) = -701.
status_number(bnd_incomplete) = -703.
status_number(bnd_rt_config_mismatch) = -704.
status_number(contract_breach) = -710.
status_number(contract_missing) = -711.
status_number(contract_invalid) = -712.
status_number(rtct_profile_refuses_dsrt) = -713.
status_number(contract_wcet_halt) = -714.
status_number(fs_version) = -720.
status_number(fs_divergence) = -725.
status_number(fs_recording_incomplete) = -729.
status_number(fs_unknown_fact_id) = -730.

number_status(0, ok).
number_status(-1, inval).
number_status(-2, oom).
number_status(-3, not_found).
number_status(-4, state).
number_status(-5, overflow).
number_status(-7, unsupported).
number_status(-8, internal).
number_status(-9, io).
number_status(-10, engine_halted).
number_status(-100, parse).
number_status(-101, schema_unknown).
number_status(-103, slot_unknown).
number_status(-104, slot_type_mismatch).
number_status(-200, fact_invalid).
number_status(-202, action_failed).
number_status(-205, time_range).
number_status(-216, nan_rejected).
number_status(-217, json_nonfinite).
number_status(-218, series_no_backing).
number_status(-219, schema_hash_mismatch).
number_status(-220, fact_ref_conflict).
number_status(-221, json_limit).
number_status(-222, encoding).
number_status(-223, not_representable).
number_status(-400, storage_unavailable).
number_status(-401, storage_query_failed).
number_status(-402, storage_not_found).
number_status(-500, dsc_truncated).
number_status(-501, dsc_bad_magic).
number_status(-502, dsc_version).
number_status(-503, dsc_decode).
number_status(-504, dsc_semantic).
number_status(-506, dsc_dangling).
number_status(-507, dsc_decompress).
number_status(-514, dsc_capability_absent).
number_status(-601, retp_invalid).
number_status(-602, retp_index_oob).
number_status(-604, fn_not_found).
number_status(-605, budget_exceeded).
number_status(-606, wm_full).
number_status(-607, token_budget).
number_status(-608, rt_unsafe).
number_status(-609, rt_live).
number_status(-610, rt_precond).
number_status(-620, backend_abi_version).
number_status(-621, backend_bad_magic).
number_status(-622, backend_bad_aggs).
number_status(-623, backend_not_registered).
number_status(-700, bnd_dsc_mismatch).
number_status(-701, bnd_dialect_mismatch).
number_status(-703, bnd_incomplete).
number_status(-704, bnd_rt_config_mismatch).
number_status(-710, contract_breach).
number_status(-711, contract_missing).
number_status(-712, contract_invalid).
number_status(-713, rtct_profile_refuses_dsrt).
number_status(-714, contract_wcet_halt).
number_status(-720, fs_version).
number_status(-725, fs_divergence).
number_status(-729, fs_recording_incomplete).
number_status(-730, fs_unknown_fact_id).

status_name(ok) = "DS_OK".
status_name(inval) = "DS_ERR_INVAL".
status_name(oom) = "DS_ERR_OOM".
status_name(not_found) = "DS_ERR_NOT_FOUND".
status_name(state) = "DS_ERR_STATE".
status_name(overflow) = "DS_ERR_OVERFLOW".
status_name(unsupported) = "DS_ERR_UNSUPPORTED".
status_name(internal) = "DS_ERR_INTERNAL".
status_name(io) = "DS_ERR_IO".
status_name(engine_halted) = "DS_ERR_ENGINE_HALTED".
status_name(parse) = "DS_ERR_PARSE".
status_name(schema_unknown) = "DS_ERR_SCHEMA_UNKNOWN".
status_name(slot_unknown) = "DS_ERR_SLOT_UNKNOWN".
status_name(slot_type_mismatch) = "DS_ERR_SLOT_TYPE_MISMATCH".
status_name(fact_invalid) = "DS_ERR_FACT_INVALID".
status_name(action_failed) = "DS_ERR_ACTION_FAILED".
status_name(time_range) = "DS_ERR_TIME_RANGE".
status_name(nan_rejected) = "DS_ERR_NAN_REJECTED".
status_name(json_nonfinite) = "DS_ERR_JSON_NONFINITE".
status_name(series_no_backing) = "DS_ERR_SERIES_NO_BACKING".
status_name(schema_hash_mismatch) = "DS_ERR_SCHEMA_HASH_MISMATCH".
status_name(fact_ref_conflict) = "DS_ERR_FACT_REF_CONFLICT".
status_name(json_limit) = "DS_ERR_JSON_LIMIT".
status_name(encoding) = "DS_ERR_ENCODING".
status_name(not_representable) = "DS_ERR_NOT_REPRESENTABLE".
status_name(storage_unavailable) = "DS_ERR_STORAGE_UNAVAILABLE".
status_name(storage_query_failed) = "DS_ERR_STORAGE_QUERY_FAILED".
status_name(storage_not_found) = "DS_ERR_STORAGE_NOT_FOUND".
status_name(dsc_truncated) = "DS_ERR_DSC_TRUNCATED".
status_name(dsc_bad_magic) = "DS_ERR_DSC_BAD_MAGIC".
status_name(dsc_version) = "DS_ERR_DSC_VERSION".
status_name(dsc_decode) = "DS_ERR_DSC_DECODE".
status_name(dsc_semantic) = "DS_ERR_DSC_SEMANTIC".
status_name(dsc_dangling) = "DS_ERR_DSC_DANGLING".
status_name(dsc_decompress) = "DS_ERR_DSC_DECOMPRESS".
status_name(dsc_capability_absent) = "DS_ERR_DSC_CAPABILITY_ABSENT".
status_name(retp_invalid) = "DS_ERR_RETP_INVALID".
status_name(retp_index_oob) = "DS_ERR_RETP_INDEX_OOB".
status_name(fn_not_found) = "DS_ERR_FN_NOT_FOUND".
status_name(budget_exceeded) = "DS_ERR_BUDGET_EXCEEDED".
status_name(wm_full) = "DS_ERR_WM_FULL".
status_name(token_budget) = "DS_ERR_TOKEN_BUDGET".
status_name(rt_unsafe) = "DS_ERR_RT_UNSAFE".
status_name(rt_live) = "DS_ERR_RT_LIVE".
status_name(rt_precond) = "DS_ERR_RT_PRECOND".
status_name(backend_abi_version) = "DS_ERR_BACKEND_ABI_VERSION".
status_name(backend_bad_magic) = "DS_ERR_BACKEND_BAD_MAGIC".
status_name(backend_bad_aggs) = "DS_ERR_BACKEND_BAD_AGGS".
status_name(backend_not_registered) = "DS_ERR_BACKEND_NOT_REGISTERED".
status_name(bnd_dsc_mismatch) = "DS_ERR_BND_DSC_MISMATCH".
status_name(bnd_dialect_mismatch) = "DS_ERR_BND_DIALECT_MISMATCH".
status_name(bnd_incomplete) = "DS_ERR_BND_INCOMPLETE".
status_name(bnd_rt_config_mismatch) = "DS_ERR_BND_RT_CONFIG_MISMATCH".
status_name(contract_breach) = "DS_ERR_CONTRACT_BREACH".
status_name(contract_missing) = "DS_ERR_CONTRACT_MISSING".
status_name(contract_invalid) = "DS_ERR_CONTRACT_INVALID".
status_name(rtct_profile_refuses_dsrt) = "DS_ERR_RTCT_PROFILE_REFUSES_DSRT".
status_name(contract_wcet_halt) = "DS_ERR_CONTRACT_WCET_HALT".
status_name(fs_version) = "DS_ERR_FS_VERSION".
status_name(fs_divergence) = "DS_ERR_FS_DIVERGENCE".
status_name(fs_recording_incomplete) = "DS_ERR_FS_RECORDING_INCOMPLETE".
status_name(fs_unknown_fact_id) = "DS_ERR_FS_UNKNOWN_FACT_ID".

%---------------------------------------------------------------------------%

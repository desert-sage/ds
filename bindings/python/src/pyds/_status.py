# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
#
# GENERATED from proto/status.proto -- do not
# edit. The `pyds` gate lane runs `--check`, so a hand edit is a red
# build. The numbers are normative; the names are labels.
"""The DS status dictionary: `proto/status.proto`'s `DsStatus`."""

import enum

__all__ = ["Status"]


class Status(enum.IntEnum):
    """A `ds_status_t`. The number is its identity; the name is a label."""

    OK = 0
    INVAL = -1
    OOM = -2
    NOT_FOUND = -3
    STATE = -4
    OVERFLOW = -5
    UNSUPPORTED = -7
    INTERNAL = -8
    IO = -9
    ENGINE_HALTED = -10
    PARSE = -100
    SCHEMA_UNKNOWN = -101
    SLOT_UNKNOWN = -103
    SLOT_TYPE_MISMATCH = -104
    FACT_INVALID = -200
    ACTION_FAILED = -202
    TIME_RANGE = -205
    NAN_REJECTED = -216
    JSON_NONFINITE = -217
    SERIES_NO_BACKING = -218
    SCHEMA_HASH_MISMATCH = -219
    FACT_REF_CONFLICT = -220
    JSON_LIMIT = -221
    ENCODING = -222
    STORAGE_UNAVAILABLE = -400
    STORAGE_QUERY_FAILED = -401
    STORAGE_NOT_FOUND = -402
    DSC_TRUNCATED = -500
    DSC_BAD_MAGIC = -501
    DSC_VERSION = -502
    DSC_DECODE = -503
    DSC_SEMANTIC = -504
    DSC_DANGLING = -506
    DSC_DECOMPRESS = -507
    DSC_CAPABILITY_ABSENT = -514
    RETP_INVALID = -601
    RETP_INDEX_OOB = -602
    FN_NOT_FOUND = -604
    BUDGET_EXCEEDED = -605
    WM_FULL = -606
    TOKEN_BUDGET = -607
    RT_UNSAFE = -608
    RT_LIVE = -609
    RT_PRECOND = -610
    BACKEND_ABI_VERSION = -620
    BACKEND_BAD_MAGIC = -621
    BACKEND_BAD_AGGS = -622
    BACKEND_NOT_REGISTERED = -623
    BND_DSC_MISMATCH = -700
    BND_DIALECT_MISMATCH = -701
    BND_INCOMPLETE = -703
    BND_RT_CONFIG_MISMATCH = -704
    CONTRACT_BREACH = -710
    CONTRACT_MISSING = -711
    CONTRACT_INVALID = -712
    RTCT_PROFILE_REFUSES_DSRT = -713
    CONTRACT_WCET_HALT = -714
    FS_VERSION = -720
    FS_DIVERGENCE = -725
    FS_UNKNOWN_INJECT = -726
    FS_RECORDING_INCOMPLETE = -729
    FS_UNKNOWN_FACT_ID = -730

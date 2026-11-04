/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its sources have drifted apart.
 *
 * The table itself. Everything that describes it — the struct, the band
 * geometry — is in atom_registry.h; the per-atom numbers are in
 * rfcs/atoms.h, which it includes.
 */
#include "atom_registry.h"

const ds_atom_reg_entry_t ds_atom_registry[DS_ATOM_REGISTRY_COUNT] = {
    {    1, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "FactAssert" },  /* DS_ATOM_FACT_ASSERT                     inject */
    {    2, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "FactRetract" },  /* DS_ATOM_FACT_RETRACT                    inject */
    {    3, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "ClockAdvance" },  /* DS_ATOM_CLOCK_ADVANCE                   inject */
    {    4, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "PumpBoundary" },  /* DS_ATOM_PUMP_BOUNDARY                   inject */
    {    5, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "ExternalAssert" },  /* DS_ATOM_EXTERNAL_ASSERT                 inject */
    {    6, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "CacheSeed" },  /* DS_ATOM_CACHE_SEED                      inject */
    {  128, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RealtimeContract" },  /* DS_ATOM_REALTIME_CONTRACT               reject */
    {  129, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendIntervalPulse" },  /* DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE   reject */
    {  130, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendNumericIntegral" },  /* DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL reject */
    {  131, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "InitialFact" },  /* DS_ATOM_INITIAL_FACT                    reject */
    {  132, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "InitialCacheSeed" },  /* DS_ATOM_INITIAL_CACHE_SEED              reject */
    {  256, DS_ATOM_LEGAL_BOTH     , DS_ATOM_CLASS_STRUCTURAL , "SchemaDef" },  /* DS_ATOM_SCHEMA_DEF                      skip */
    {  257, DS_ATOM_LEGAL_BOTH     , DS_ATOM_CLASS_STRUCTURAL , "Slot" },  /* DS_ATOM_SLOT                            skip */
    {  258, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_STRUCTURAL , "StreamHeader" },  /* DS_ATOM_STREAM_HEADER                   skip */
    {  261, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "RuleFireAnnotation" },  /* DS_ATOM_RULE_FIRE_ANNOTATION            skip */
    {  262, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "CallIssued" },  /* DS_ATOM_CALL_ISSUED                     skip */
    {  263, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DscHeader" },  /* DS_ATOM_DSC_HEADER                      skip */
    {  264, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DialectInfo" },  /* DS_ATOM_DIALECT_INFO                    skip */
    {  265, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "CapabilityInfo" },  /* DS_ATOM_CAPABILITY_INFO                 skip */
    {  267, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DsSource" },  /* DS_ATOM_DS_SOURCE                       skip */
    {  268, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "AlphaNode" },  /* DS_ATOM_ALPHA_NODE                      skip */
    {  269, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "BetaNode" },  /* DS_ATOM_BETA_NODE                       skip */
    {  270, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TerminalNode" },  /* DS_ATOM_TERMINAL_NODE                   skip */
    {  287, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleActivated" },  /* DS_ATOM_ORACLE_ACTIVATED                skip */
    {  288, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleEmit" },  /* DS_ATOM_ORACLE_EMIT                     skip */
    {  289, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OraclePublish" },  /* DS_ATOM_ORACLE_PUBLISH                  skip */
    {  290, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCall" },  /* DS_ATOM_ORACLE_CALL                     skip */
    {  291, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCacheSet" },  /* DS_ATOM_ORACLE_CACHE_SET                skip */
    {  292, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCacheDelete" },  /* DS_ATOM_ORACLE_CACHE_DELETE             skip */
    {  294, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleLog" },  /* DS_ATOM_ORACLE_LOG                      skip */
    {  296, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleRetract" },  /* DS_ATOM_ORACLE_RETRACT                  skip */
    {  297, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleWorkingMemory" },  /* DS_ATOM_ORACLE_WORKING_MEMORY           skip */
    {  298, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "CompiledCode" },  /* DS_ATOM_COMPILED_CODE                   skip */
    {  299, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaLogical" },  /* DS_ATOM_SCHEMA_LOGICAL                  skip */
    {  300, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaTtl" },  /* DS_ATOM_SCHEMA_TTL                      skip */
    {  301, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "Hydration" },  /* DS_ATOM_HYDRATION                       skip */
    {  302, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaSource" },  /* DS_ATOM_SCHEMA_SOURCE                   skip */
    {  303, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "LineSpan" },  /* DS_ATOM_LINE_SPAN                       skip */
    {  304, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DocString" },  /* DS_ATOM_DOC_STRING                      skip */
    {  307, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleCooldown" },  /* DS_ATOM_RULE_COOLDOWN                   skip */
    {  309, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleSource" },  /* DS_ATOM_RULE_SOURCE                     skip */
    {  310, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleDebugName" },  /* DS_ATOM_RULE_DEBUG_NAME                 skip */
    {  311, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "ServiceDef" },  /* DS_ATOM_SERVICE_DEF                     skip */
    {  312, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendWelfordEwma" },  /* DS_ATOM_SERIES_BACKEND_WELFORD_EWMA     skip */
    {  313, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendRingBuffer" },  /* DS_ATOM_SERIES_BACKEND_RING_BUFFER      skip */
    {  314, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendMonotonicDeque" },  /* DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE  skip */
    {  315, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendFifoDeque" },  /* DS_ATOM_SERIES_BACKEND_FIFO_DEQUE       skip */
    {  316, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendReservoir" },  /* DS_ATOM_SERIES_BACKEND_RESERVOIR        skip */
    {  317, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestCase" },  /* DS_ATOM_TEST_CASE                       skip */
    {  318, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestFact" },  /* DS_ATOM_TEST_FACT                       skip */
    {  319, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestCacheSeed" },  /* DS_ATOM_TEST_CACHE_SEED                 skip */
    {  320, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestResponse" },  /* DS_ATOM_TEST_RESPONSE                   skip */
    {  321, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestReply" },  /* DS_ATOM_TEST_REPLY                      skip */
    {  324, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleExclusive" },  /* DS_ATOM_ORACLE_EXCLUSIVE                skip */
    {  325, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "ComputationError" },  /* DS_ATOM_COMPUTATION_ERROR               skip */
    {  326, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactEmit" },  /* DS_ATOM_FACT_EMIT                       skip */
    {  327, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactWithdraw" },  /* DS_ATOM_FACT_WITHDRAW                   skip */
    {  328, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "TypeError" },  /* DS_ATOM_TYPE_ERROR                      skip */
    {  329, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "BoundsError" },  /* DS_ATOM_BOUNDS_ERROR                    skip */
    {  330, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "EngineError" },  /* DS_ATOM_ENGINE_ERROR                    skip */
    {  331, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactPublish" },  /* DS_ATOM_FACT_PUBLISH                    skip */
};

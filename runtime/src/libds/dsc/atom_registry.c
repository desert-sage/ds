/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its sources have drifted apart.
 *
 * The table itself. The struct that describes it is in atom_registry.h;
 * the per-atom numbers are in rfcs/atoms.h, which it includes.
 */
#include "atom_registry.h"

const ds_atom_reg_entry_t ds_atom_registry[DS_ATOM_REGISTRY_COUNT] = {
    {    1, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "FactAssert" },  /* DS_ATOM_FACT_ASSERT */
    {    2, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "FactRetract" },  /* DS_ATOM_FACT_RETRACT */
    {    3, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "ClockAdvance" },  /* DS_ATOM_CLOCK_ADVANCE */
    {    4, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "PumpBoundary" },  /* DS_ATOM_PUMP_BOUNDARY */
    {    5, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "ExternalAssert" },  /* DS_ATOM_EXTERNAL_ASSERT */
    {    6, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_INJECT     , "CacheSeed" },  /* DS_ATOM_CACHE_SEED */
    {  128, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RealtimeContract" },  /* DS_ATOM_REALTIME_CONTRACT */
    {  129, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendIntervalPulse" },  /* DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE */
    {  130, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendNumericIntegral" },  /* DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL */
    {  131, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "InitialFact" },  /* DS_ATOM_INITIAL_FACT */
    {  132, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "InitialCacheSeed" },  /* DS_ATOM_INITIAL_CACHE_SEED */
    {  256, DS_ATOM_LEGAL_BOTH     , DS_ATOM_CLASS_STRUCTURAL , "SchemaDef" },  /* DS_ATOM_SCHEMA_DEF */
    {  257, DS_ATOM_LEGAL_BOTH     , DS_ATOM_CLASS_STRUCTURAL , "Slot" },  /* DS_ATOM_SLOT */
    {  258, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_STRUCTURAL , "StreamHeader" },  /* DS_ATOM_STREAM_HEADER */
    {  261, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "RuleFireAnnotation" },  /* DS_ATOM_RULE_FIRE_ANNOTATION */
    {  262, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "CallIssued" },  /* DS_ATOM_CALL_ISSUED */
    {  263, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DscHeader" },  /* DS_ATOM_DSC_HEADER */
    {  264, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DialectInfo" },  /* DS_ATOM_DIALECT_INFO */
    {  265, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "CapabilityInfo" },  /* DS_ATOM_CAPABILITY_INFO */
    {  267, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DsSource" },  /* DS_ATOM_DS_SOURCE */
    {  268, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "AlphaNode" },  /* DS_ATOM_ALPHA_NODE */
    {  269, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "BetaNode" },  /* DS_ATOM_BETA_NODE */
    {  270, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TerminalNode" },  /* DS_ATOM_TERMINAL_NODE */
    {  287, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleActivated" },  /* DS_ATOM_ORACLE_ACTIVATED */
    {  288, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleEmit" },  /* DS_ATOM_ORACLE_EMIT */
    {  289, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OraclePublish" },  /* DS_ATOM_ORACLE_PUBLISH */
    {  290, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCall" },  /* DS_ATOM_ORACLE_CALL */
    {  291, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCacheSet" },  /* DS_ATOM_ORACLE_CACHE_SET */
    {  292, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleCacheDelete" },  /* DS_ATOM_ORACLE_CACHE_DELETE */
    {  294, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleLog" },  /* DS_ATOM_ORACLE_LOG */
    {  296, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleRetract" },  /* DS_ATOM_ORACLE_RETRACT */
    {  297, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleWorkingMemory" },  /* DS_ATOM_ORACLE_WORKING_MEMORY */
    {  298, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "CompiledCode" },  /* DS_ATOM_COMPILED_CODE */
    {  299, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaLogical" },  /* DS_ATOM_SCHEMA_LOGICAL */
    {  300, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaTtl" },  /* DS_ATOM_SCHEMA_TTL */
    {  301, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "Hydration" },  /* DS_ATOM_HYDRATION */
    {  302, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SchemaSource" },  /* DS_ATOM_SCHEMA_SOURCE */
    {  303, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "LineSpan" },  /* DS_ATOM_LINE_SPAN */
    {  304, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "DocString" },  /* DS_ATOM_DOC_STRING */
    {  307, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleCooldown" },  /* DS_ATOM_RULE_COOLDOWN */
    {  309, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleSource" },  /* DS_ATOM_RULE_SOURCE */
    {  310, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "RuleDebugName" },  /* DS_ATOM_RULE_DEBUG_NAME */
    {  311, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "ServiceDef" },  /* DS_ATOM_SERVICE_DEF */
    {  312, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendWelfordEwma" },  /* DS_ATOM_SERIES_BACKEND_WELFORD_EWMA */
    {  313, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendRingBuffer" },  /* DS_ATOM_SERIES_BACKEND_RING_BUFFER */
    {  314, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendMonotonicDeque" },  /* DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE */
    {  315, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendFifoDeque" },  /* DS_ATOM_SERIES_BACKEND_FIFO_DEQUE */
    {  316, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "SeriesBackendReservoir" },  /* DS_ATOM_SERIES_BACKEND_RESERVOIR */
    {  317, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestCase" },  /* DS_ATOM_TEST_CASE */
    {  318, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestFact" },  /* DS_ATOM_TEST_FACT */
    {  319, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestCacheSeed" },  /* DS_ATOM_TEST_CACHE_SEED */
    {  320, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestResponse" },  /* DS_ATOM_TEST_RESPONSE */
    {  321, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "TestReply" },  /* DS_ATOM_TEST_REPLY */
    {  324, DS_ATOM_LEGAL_DSC      , DS_ATOM_CLASS_NONE       , "OracleExclusive" },  /* DS_ATOM_ORACLE_EXCLUSIVE */
    {  325, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "ComputationError" },  /* DS_ATOM_COMPUTATION_ERROR */
    {  326, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactEmit" },  /* DS_ATOM_FACT_EMIT */
    {  327, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactWithdraw" },  /* DS_ATOM_FACT_WITHDRAW */
    {  328, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "TypeError" },  /* DS_ATOM_TYPE_ERROR */
    {  329, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "BoundsError" },  /* DS_ATOM_BOUNDS_ERROR */
    {  330, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "EngineError" },  /* DS_ATOM_ENGINE_ERROR */
    {  331, DS_ATOM_LEGAL_STREAM   , DS_ATOM_CLASS_COMPARE    , "FactPublish" },  /* DS_ATOM_FACT_PUBLISH */
};

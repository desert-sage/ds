/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its sources have drifted apart.
 *
 * The field number of every allocated atom ([RFCS.16.1]), the wire
 * identity the rfcs API names an atom by, under its body message's
 * name (`FactAssert` is DS_ATOM_FACT_ASSERT). Shipped beside rfcs.h as
 * include/internal/rfcs/atoms.h.
 */
#ifndef DS_RFCS_ATOMS_H
#define DS_RFCS_ATOMS_H

#define DS_ATOM_FACT_ASSERT 1u  /* FactAssert */
#define DS_ATOM_FACT_RETRACT 2u  /* FactRetract */
#define DS_ATOM_CLOCK_ADVANCE 3u  /* ClockAdvance */
#define DS_ATOM_PUMP_BOUNDARY 4u  /* PumpBoundary */
#define DS_ATOM_EXTERNAL_ASSERT 5u  /* ExternalAssert */
#define DS_ATOM_CACHE_SEED 6u  /* CacheSeed */
#define DS_ATOM_REALTIME_CONTRACT 128u  /* RealtimeContract */
#define DS_ATOM_SERIES_BACKEND_INTERVAL_PULSE 129u  /* SeriesBackendIntervalPulse */
#define DS_ATOM_SERIES_BACKEND_NUMERIC_INTEGRAL 130u  /* SeriesBackendNumericIntegral */
#define DS_ATOM_INITIAL_FACT 131u  /* InitialFact */
#define DS_ATOM_INITIAL_CACHE_SEED 132u  /* InitialCacheSeed */
#define DS_ATOM_SCHEMA_DEF 256u  /* SchemaDef */
#define DS_ATOM_SLOT 257u  /* Slot */
#define DS_ATOM_STREAM_HEADER 258u  /* StreamHeader */
#define DS_ATOM_RULE_FIRE_ANNOTATION 261u  /* RuleFireAnnotation */
#define DS_ATOM_CALL_ISSUED 262u  /* CallIssued */
#define DS_ATOM_DSC_HEADER 263u  /* DscHeader */
#define DS_ATOM_DIALECT_INFO 264u  /* DialectInfo */
#define DS_ATOM_CAPABILITY_INFO 265u  /* CapabilityInfo */
#define DS_ATOM_DS_SOURCE 267u  /* DsSource */
#define DS_ATOM_ALPHA_NODE 268u  /* AlphaNode */
#define DS_ATOM_BETA_NODE 269u  /* BetaNode */
#define DS_ATOM_TERMINAL_NODE 270u  /* TerminalNode */
#define DS_ATOM_ORACLE_ACTIVATED 287u  /* OracleActivated */
#define DS_ATOM_ORACLE_EMIT 288u  /* OracleEmit */
#define DS_ATOM_ORACLE_PUBLISH 289u  /* OraclePublish */
#define DS_ATOM_ORACLE_CALL 290u  /* OracleCall */
#define DS_ATOM_ORACLE_CACHE_SET 291u  /* OracleCacheSet */
#define DS_ATOM_ORACLE_CACHE_DELETE 292u  /* OracleCacheDelete */
#define DS_ATOM_ORACLE_LOG 294u  /* OracleLog */
#define DS_ATOM_ORACLE_RETRACT 296u  /* OracleRetract */
#define DS_ATOM_ORACLE_WORKING_MEMORY 297u  /* OracleWorkingMemory */
#define DS_ATOM_COMPILED_CODE 298u  /* CompiledCode */
#define DS_ATOM_SCHEMA_LOGICAL 299u  /* SchemaLogical */
#define DS_ATOM_SCHEMA_TTL 300u  /* SchemaTtl */
#define DS_ATOM_HYDRATION 301u  /* Hydration */
#define DS_ATOM_SCHEMA_SOURCE 302u  /* SchemaSource */
#define DS_ATOM_LINE_SPAN 303u  /* LineSpan */
#define DS_ATOM_DOC_STRING 304u  /* DocString */
#define DS_ATOM_RULE_COOLDOWN 307u  /* RuleCooldown */
#define DS_ATOM_RULE_SOURCE 309u  /* RuleSource */
#define DS_ATOM_RULE_DEBUG_NAME 310u  /* RuleDebugName */
#define DS_ATOM_SERVICE_DEF 311u  /* ServiceDef */
#define DS_ATOM_SERIES_BACKEND_WELFORD_EWMA 312u  /* SeriesBackendWelfordEwma */
#define DS_ATOM_SERIES_BACKEND_RING_BUFFER 313u  /* SeriesBackendRingBuffer */
#define DS_ATOM_SERIES_BACKEND_MONOTONIC_DEQUE 314u  /* SeriesBackendMonotonicDeque */
#define DS_ATOM_SERIES_BACKEND_FIFO_DEQUE 315u  /* SeriesBackendFifoDeque */
#define DS_ATOM_SERIES_BACKEND_RESERVOIR 316u  /* SeriesBackendReservoir */
#define DS_ATOM_TEST_CASE 317u  /* TestCase */
#define DS_ATOM_TEST_FACT 318u  /* TestFact */
#define DS_ATOM_TEST_CACHE_SEED 319u  /* TestCacheSeed */
#define DS_ATOM_TEST_RESPONSE 320u  /* TestResponse */
#define DS_ATOM_TEST_REPLY 321u  /* TestReply */
#define DS_ATOM_ORACLE_EXCLUSIVE 324u  /* OracleExclusive */
#define DS_ATOM_COMPUTATION_ERROR 325u  /* ComputationError */
#define DS_ATOM_FACT_EMIT 326u  /* FactEmit */
#define DS_ATOM_FACT_WITHDRAW 327u  /* FactWithdraw */
#define DS_ATOM_TYPE_ERROR 328u  /* TypeError */
#define DS_ATOM_BOUNDS_ERROR 329u  /* BoundsError */
#define DS_ATOM_ENGINE_ERROR 330u  /* EngineError */
#define DS_ATOM_FACT_PUBLISH 331u  /* FactPublish */

#endif /* DS_RFCS_ATOMS_H */

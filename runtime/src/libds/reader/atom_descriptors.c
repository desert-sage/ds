/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its sources have drifted apart.
 *
 * The descriptor table itself. Every body proto is compiled into libds:
 * the dsc and rfcs sets, and the reader set for the eight only this
 * table needs (libds.build).
 */
#include "atom_descriptors.h"

#include "alfa.pb-c.h"
#include "aot.pb-c.h"
#include "beta.pb-c.h"
#include "bounds_error.pb-c.h"
#include "cache_seed.pb-c.h"
#include "call_issued.pb-c.h"
#include "capabilities.pb-c.h"
#include "dialect.pb-c.h"
#include "doc_string.pb-c.h"
#include "ds_source.pb-c.h"
#include "engine_error.pb-c.h"
#include "engine_fault.pb-c.h"
#include "external_assert.pb-c.h"
#include "fact_assert.pb-c.h"
#include "fact_emit.pb-c.h"
#include "fact_publish.pb-c.h"
#include "fact_retract.pb-c.h"
#include "fact_withdraw.pb-c.h"
#include "header.pb-c.h"
#include "hydration.pb-c.h"
#include "initial.pb-c.h"
#include "line_span.pb-c.h"
#include "pump_boundary.pb-c.h"
#include "realtime_contract.pb-c.h"
#include "rule_cooldown.pb-c.h"
#include "rule_debug_name.pb-c.h"
#include "rule_source.pb-c.h"
#include "schema_def.pb-c.h"
#include "schema_logical.pb-c.h"
#include "schema_source.pb-c.h"
#include "schema_ttl.pb-c.h"
#include "series_backend_fifo_deque.pb-c.h"
#include "series_backend_interval_pulse.pb-c.h"
#include "series_backend_monotonic_deque.pb-c.h"
#include "series_backend_numeric_integral.pb-c.h"
#include "series_backend_reservoir.pb-c.h"
#include "series_backend_ring_buffer.pb-c.h"
#include "series_backend_welford_ewma.pb-c.h"
#include "service_def.pb-c.h"
#include "slot.pb-c.h"
#include "stream_header.pb-c.h"
#include "term.pb-c.h"
#include "test_oracle.pb-c.h"
#include "test_scenario.pb-c.h"
#include "type_error.pb-c.h"

const ProtobufCMessageDescriptor *const
    ds_atom_descriptors[DS_ATOM_REGISTRY_COUNT] = {
    &ds__v1__fact_assert__descriptor,  /*    1 FactAssert */
    &ds__v1__fact_retract__descriptor,  /*    2 FactRetract */
    &ds__v1__clock_advance__descriptor,  /*    3 ClockAdvance */
    &ds__v1__pump_boundary__descriptor,  /*    4 PumpBoundary */
    &ds__v1__external_assert__descriptor,  /*    5 ExternalAssert */
    &ds__v1__cache_seed__descriptor,  /*    6 CacheSeed */
    &ds__v1__realtime_contract__descriptor,  /*  128 RealtimeContract */
    &ds__v1__series_backend_interval_pulse__descriptor,  /*  129 SeriesBackendIntervalPulse */
    &ds__v1__series_backend_numeric_integral__descriptor,  /*  130 SeriesBackendNumericIntegral */
    &ds__v1__initial_fact__descriptor,  /*  131 InitialFact */
    &ds__v1__initial_cache_seed__descriptor,  /*  132 InitialCacheSeed */
    &ds__v1__schema_def__descriptor,  /*  256 SchemaDef */
    &ds__v1__slot__descriptor,  /*  257 Slot */
    &ds__v1__stream_header__descriptor,  /*  258 StreamHeader */
    &ds__v1__rule_fire_annotation__descriptor,  /*  261 RuleFireAnnotation */
    &ds__v1__call_issued__descriptor,  /*  262 CallIssued */
    &ds__v1__dsc_header__descriptor,  /*  263 DscHeader */
    &ds__v1__dialect_info__descriptor,  /*  264 DialectInfo */
    &ds__v1__capability_info__descriptor,  /*  265 CapabilityInfo */
    &ds__v1__ds_source__descriptor,  /*  267 DsSource */
    &ds__v1__alpha_node__descriptor,  /*  268 AlphaNode */
    &ds__v1__beta_node__descriptor,  /*  269 BetaNode */
    &ds__v1__terminal_node__descriptor,  /*  270 TerminalNode */
    &ds__v1__oracle_activated__descriptor,  /*  287 OracleActivated */
    &ds__v1__oracle_emit__descriptor,  /*  288 OracleEmit */
    &ds__v1__oracle_publish__descriptor,  /*  289 OraclePublish */
    &ds__v1__oracle_call__descriptor,  /*  290 OracleCall */
    &ds__v1__oracle_cache_set__descriptor,  /*  291 OracleCacheSet */
    &ds__v1__oracle_cache_delete__descriptor,  /*  292 OracleCacheDelete */
    &ds__v1__oracle_log__descriptor,  /*  294 OracleLog */
    &ds__v1__oracle_retract__descriptor,  /*  296 OracleRetract */
    &ds__v1__oracle_working_memory__descriptor,  /*  297 OracleWorkingMemory */
    &ds__v1__compiled_code__descriptor,  /*  298 CompiledCode */
    &ds__v1__schema_logical__descriptor,  /*  299 SchemaLogical */
    &ds__v1__schema_ttl__descriptor,  /*  300 SchemaTtl */
    &ds__v1__hydration__descriptor,  /*  301 Hydration */
    &ds__v1__schema_source__descriptor,  /*  302 SchemaSource */
    &ds__v1__line_span__descriptor,  /*  303 LineSpan */
    &ds__v1__doc_string__descriptor,  /*  304 DocString */
    &ds__v1__rule_cooldown__descriptor,  /*  307 RuleCooldown */
    &ds__v1__rule_source__descriptor,  /*  309 RuleSource */
    &ds__v1__rule_debug_name__descriptor,  /*  310 RuleDebugName */
    &ds__v1__service_def__descriptor,  /*  311 ServiceDef */
    &ds__v1__series_backend_welford_ewma__descriptor,  /*  312 SeriesBackendWelfordEwma */
    &ds__v1__series_backend_ring_buffer__descriptor,  /*  313 SeriesBackendRingBuffer */
    &ds__v1__series_backend_monotonic_deque__descriptor,  /*  314 SeriesBackendMonotonicDeque */
    &ds__v1__series_backend_fifo_deque__descriptor,  /*  315 SeriesBackendFifoDeque */
    &ds__v1__series_backend_reservoir__descriptor,  /*  316 SeriesBackendReservoir */
    &ds__v1__test_case__descriptor,  /*  317 TestCase */
    &ds__v1__test_fact__descriptor,  /*  318 TestFact */
    &ds__v1__test_cache_seed__descriptor,  /*  319 TestCacheSeed */
    &ds__v1__test_response__descriptor,  /*  320 TestResponse */
    &ds__v1__test_reply__descriptor,  /*  321 TestReply */
    &ds__v1__oracle_exclusive__descriptor,  /*  324 OracleExclusive */
    &ds__v1__computation_error__descriptor,  /*  325 ComputationError */
    &ds__v1__fact_emit__descriptor,  /*  326 FactEmit */
    &ds__v1__fact_withdraw__descriptor,  /*  327 FactWithdraw */
    &ds__v1__type_error__descriptor,  /*  328 TypeError */
    &ds__v1__bounds_error__descriptor,  /*  329 BoundsError */
    &ds__v1__engine_error__descriptor,  /*  330 EngineError */
    &ds__v1__fact_publish__descriptor,  /*  331 FactPublish */
};

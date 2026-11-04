# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""GENERATED — do not edit; regenerate it. A drift check fails if this
file and its sources have drifted apart.

The atom registry for pyds: the map the C reader gets from
atom_registry.{h,c}. Sources: proto/atom.proto (number <-> body message,
[RFCS.16.1]), [RFCS.3.1] + [RDSC.7.1] (container-legality and
stream-class columns).

An atom is named by its body message: `AtomKind.FACT_ASSERT`,
value 1, `.message` "FactAssert". The field number is the whole of an
atom's wire identity ([RFCS.16.1]); an atom this build does not know is
a plain `int`, since [RFCS.16.3] leaves the set open to a reader.
"""

import enum

# [RFCS.16.2] — band boundaries. Powers of two, so a reader classifies an
# unknown number by magnitude and needs no table entry for it.
BAND_INJECT_LO = 1
BAND_INJECT_HI = 127
BAND_REJECT_LO = 128
BAND_REJECT_HI = 255
BAND_SKIP_LO = 256
BAND_SKIP_HI = 2047

# [RFCS.17.1] container-legality. A bitmask: an atom may be legal in both.
LEGAL_DSC = 0x1
LEGAL_STREAM = 0x2
LEGAL_BOTH = LEGAL_DSC | LEGAL_STREAM

# field number -> (body message, legality bitmask, [RFCS.3.4] replay
# class). The class is "none" exactly when the atom is not stream-legal.
REGISTRY: dict[int, tuple[str, int, str]] = {
       1: ("FactAssert", LEGAL_STREAM, "inject"),  # inject
       2: ("FactRetract", LEGAL_STREAM, "inject"),  # inject
       3: ("ClockAdvance", LEGAL_STREAM, "inject"),  # inject
       4: ("PumpBoundary", LEGAL_STREAM, "inject"),  # inject
       5: ("ExternalAssert", LEGAL_STREAM, "inject"),  # inject
       6: ("CacheSeed", LEGAL_STREAM, "inject"),  # inject
     128: ("RealtimeContract", LEGAL_DSC   , "none"),  # reject
     129: ("SeriesBackendIntervalPulse", LEGAL_DSC   , "none"),  # reject
     130: ("SeriesBackendNumericIntegral", LEGAL_DSC   , "none"),  # reject
     131: ("InitialFact", LEGAL_DSC   , "none"),  # reject
     132: ("InitialCacheSeed", LEGAL_DSC   , "none"),  # reject
     256: ("SchemaDef", LEGAL_BOTH  , "structural"),  # skip
     257: ("Slot", LEGAL_BOTH  , "structural"),  # skip
     258: ("StreamHeader", LEGAL_STREAM, "structural"),  # skip
     261: ("RuleFireAnnotation", LEGAL_STREAM, "compare"),  # skip
     262: ("CallIssued", LEGAL_STREAM, "compare"),  # skip
     263: ("DscHeader", LEGAL_DSC   , "none"),  # skip
     264: ("DialectInfo", LEGAL_DSC   , "none"),  # skip
     265: ("CapabilityInfo", LEGAL_DSC   , "none"),  # skip
     267: ("DsSource", LEGAL_DSC   , "none"),  # skip
     268: ("AlphaNode", LEGAL_DSC   , "none"),  # skip
     269: ("BetaNode", LEGAL_DSC   , "none"),  # skip
     270: ("TerminalNode", LEGAL_DSC   , "none"),  # skip
     287: ("OracleActivated", LEGAL_DSC   , "none"),  # skip
     288: ("OracleEmit", LEGAL_DSC   , "none"),  # skip
     289: ("OraclePublish", LEGAL_DSC   , "none"),  # skip
     290: ("OracleCall", LEGAL_DSC   , "none"),  # skip
     291: ("OracleCacheSet", LEGAL_DSC   , "none"),  # skip
     292: ("OracleCacheDelete", LEGAL_DSC   , "none"),  # skip
     294: ("OracleLog", LEGAL_DSC   , "none"),  # skip
     296: ("OracleRetract", LEGAL_DSC   , "none"),  # skip
     297: ("OracleWorkingMemory", LEGAL_DSC   , "none"),  # skip
     298: ("CompiledCode", LEGAL_DSC   , "none"),  # skip
     299: ("SchemaLogical", LEGAL_DSC   , "none"),  # skip
     300: ("SchemaTtl", LEGAL_DSC   , "none"),  # skip
     301: ("Hydration", LEGAL_DSC   , "none"),  # skip
     302: ("SchemaSource", LEGAL_DSC   , "none"),  # skip
     303: ("LineSpan", LEGAL_DSC   , "none"),  # skip
     304: ("DocString", LEGAL_DSC   , "none"),  # skip
     307: ("RuleCooldown", LEGAL_DSC   , "none"),  # skip
     309: ("RuleSource", LEGAL_DSC   , "none"),  # skip
     310: ("RuleDebugName", LEGAL_DSC   , "none"),  # skip
     311: ("ServiceDef", LEGAL_DSC   , "none"),  # skip
     312: ("SeriesBackendWelfordEwma", LEGAL_DSC   , "none"),  # skip
     313: ("SeriesBackendRingBuffer", LEGAL_DSC   , "none"),  # skip
     314: ("SeriesBackendMonotonicDeque", LEGAL_DSC   , "none"),  # skip
     315: ("SeriesBackendFifoDeque", LEGAL_DSC   , "none"),  # skip
     316: ("SeriesBackendReservoir", LEGAL_DSC   , "none"),  # skip
     317: ("TestCase", LEGAL_DSC   , "none"),  # skip
     318: ("TestFact", LEGAL_DSC   , "none"),  # skip
     319: ("TestCacheSeed", LEGAL_DSC   , "none"),  # skip
     320: ("TestResponse", LEGAL_DSC   , "none"),  # skip
     321: ("TestReply", LEGAL_DSC   , "none"),  # skip
     324: ("OracleExclusive", LEGAL_DSC   , "none"),  # skip
     325: ("ComputationError", LEGAL_STREAM, "compare"),  # skip
     326: ("FactEmit", LEGAL_STREAM, "compare"),  # skip
     327: ("FactWithdraw", LEGAL_STREAM, "compare"),  # skip
     328: ("TypeError", LEGAL_STREAM, "compare"),  # skip
     329: ("BoundsError", LEGAL_STREAM, "compare"),  # skip
     330: ("EngineError", LEGAL_STREAM, "compare"),  # skip
     331: ("FactPublish", LEGAL_STREAM, "compare"),  # skip
}

# field number -> the proto message its body parses as ([RFCS.16.1]).
MESSAGE_BY_FIELD: dict[int, str] = {
    number: message for number, (message, _, _) in REGISTRY.items()
}

FIELD_BY_MESSAGE: dict[str, int] = {
    message: number for number, message in MESSAGE_BY_FIELD.items()
}


class AtomKind(enum.IntEnum):
    """An allocated atom: its value is the field number, its name the
    body message in constant spelling, `.message` the body message."""

    FACT_ASSERT                     = 1
    FACT_RETRACT                    = 2
    CLOCK_ADVANCE                   = 3
    PUMP_BOUNDARY                   = 4
    EXTERNAL_ASSERT                 = 5
    CACHE_SEED                      = 6
    REALTIME_CONTRACT               = 128
    SERIES_BACKEND_INTERVAL_PULSE   = 129
    SERIES_BACKEND_NUMERIC_INTEGRAL = 130
    INITIAL_FACT                    = 131
    INITIAL_CACHE_SEED              = 132
    SCHEMA_DEF                      = 256
    SLOT                            = 257
    STREAM_HEADER                   = 258
    RULE_FIRE_ANNOTATION            = 261
    CALL_ISSUED                     = 262
    DSC_HEADER                      = 263
    DIALECT_INFO                    = 264
    CAPABILITY_INFO                 = 265
    DS_SOURCE                       = 267
    ALPHA_NODE                      = 268
    BETA_NODE                       = 269
    TERMINAL_NODE                   = 270
    ORACLE_ACTIVATED                = 287
    ORACLE_EMIT                     = 288
    ORACLE_PUBLISH                  = 289
    ORACLE_CALL                     = 290
    ORACLE_CACHE_SET                = 291
    ORACLE_CACHE_DELETE             = 292
    ORACLE_LOG                      = 294
    ORACLE_RETRACT                  = 296
    ORACLE_WORKING_MEMORY           = 297
    COMPILED_CODE                   = 298
    SCHEMA_LOGICAL                  = 299
    SCHEMA_TTL                      = 300
    HYDRATION                       = 301
    SCHEMA_SOURCE                   = 302
    LINE_SPAN                       = 303
    DOC_STRING                      = 304
    RULE_COOLDOWN                   = 307
    RULE_SOURCE                     = 309
    RULE_DEBUG_NAME                 = 310
    SERVICE_DEF                     = 311
    SERIES_BACKEND_WELFORD_EWMA     = 312
    SERIES_BACKEND_RING_BUFFER      = 313
    SERIES_BACKEND_MONOTONIC_DEQUE  = 314
    SERIES_BACKEND_FIFO_DEQUE       = 315
    SERIES_BACKEND_RESERVOIR        = 316
    TEST_CASE                       = 317
    TEST_FACT                       = 318
    TEST_CACHE_SEED                 = 319
    TEST_RESPONSE                   = 320
    TEST_REPLY                      = 321
    ORACLE_EXCLUSIVE                = 324
    COMPUTATION_ERROR               = 325
    FACT_EMIT                       = 326
    FACT_WITHDRAW                   = 327
    TYPE_ERROR                      = 328
    BOUNDS_ERROR                    = 329
    ENGINE_ERROR                    = 330
    FACT_PUBLISH                    = 331

    @property
    def message(self) -> str:
        return MESSAGE_BY_FIELD[self.value]

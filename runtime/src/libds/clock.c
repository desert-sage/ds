/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * clock.c — engine clock source and public clock APIs. The only file in libds
 * that reads host time ([IARC.3.11]).
 */
#include "libds.h"

#include "clock.h"
#include "engine.h"
#include "recorder.h"

#ifdef DS_MICRO
/* From the embedded platform shim. Monotonic ns; the zero point is unspecified. */
extern uint64_t ds_platform_now_ns(void);

/* A board may supply the live wall clock: false while it has no value. A board
 * that does not define it leaves the live wall clock unset. */
extern bool ds_platform_wall_ns(int64_t *out_utc_ns) __attribute__((weak));

static uint64_t read_monotonic_ns(void)
{
    return ds_platform_now_ns();
}

static bool read_wall_ns(int64_t *out_utc_ns)
{
    return ds_platform_wall_ns != NULL && ds_platform_wall_ns(out_utc_ns);
}
#else
#include <time.h>

static uint64_t read_monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ULL + (uint64_t) ts.tv_nsec;
}

/* UTC ns since the Unix epoch ([LTIM.2.8.3]). */
static bool read_wall_ns(int64_t *out_utc_ns)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return false;
    *out_utc_ns = (int64_t) ts.tv_sec * 1000000000LL + (int64_t) ts.tv_nsec;
    return true;
}
#endif

uint64_t ds_clock_platform_mono_ns(void)
{
    return read_monotonic_ns();
}

bool ds_clock_platform_wall_ns(int64_t *out_utc_ns)
{
    return read_wall_ns(out_utc_ns);
}

ds_result_t ds_clock_init(ds_clock_t *clock)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }

    *clock = (ds_clock_t){ 0 };
    clock->mode         = DS_CLOCK_LIVE;
    clock->live_base_ns = read_monotonic_ns();
    return DS_OK_R;
}

/* The top of the monotonic clock's range ([LTIM.2.8.2]). */
#define DS_CLOCK_TOP_NS ((uint64_t) INT64_MAX)

/* A live clock continuing from a mock one can read past the top, and no host
   call is there to refuse it: the reading is held at the top ([LTIM.2.8.2]). */
static uint64_t source_mono_ns(const ds_clock_t *clock)
{
    if (clock->mode == DS_CLOCK_MOCK) return clock->mock_now_ns;
    const uint64_t now_ns = read_monotonic_ns() - clock->live_base_ns;
    return now_ns > DS_CLOCK_TOP_NS ? DS_CLOCK_TOP_NS : now_ns;
}

void ds_clock_read(const ds_clock_t *clock, ds_clock_reading_t *out)
{
    int64_t wall = 0;
    out->mono_ns = source_mono_ns(clock);
    if (clock->mode == DS_CLOCK_MOCK) {
        out->wall_set = clock->mock_wall_set;
        wall          = clock->mock_wall_ns;
    } else {
        out->wall_set = read_wall_ns(&wall);
    }
    out->wall_ns = out->wall_set ? wall : 0;
}

ds_result_t ds_clock_sample(ds_clock_t *clock, ds_clock_step_t step,
                            const ds_clock_reading_t *reading,
                            bool *out_record)
{
    if (clock == NULL || reading == NULL || out_record == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
                        "clock, reading and out_record must not be null");
    }

    /* No clamp: neither source goes backward after the first sample
       ([LTIM.2.8.2], [NTST.3.1]). */
    clock->held_mono_ns  = reading->mono_ns;
    clock->held_wall_set = reading->wall_set;
    clock->held_wall_ns  = reading->wall_ns;
    (void) step;
    clock->sampled = true;

    *out_record = !clock->recorded
               || clock->rec_mono_ns  != clock->held_mono_ns
               || clock->rec_wall_set != clock->held_wall_set
               || clock->rec_wall_ns  != clock->held_wall_ns;
    return DS_OK_R;
}

void ds_clock_mark_recorded(ds_clock_t *clock)
{
    clock->recorded     = true;
    clock->rec_mono_ns  = clock->held_mono_ns;
    clock->rec_wall_set = clock->held_wall_set;
    clock->rec_wall_ns  = clock->held_wall_ns;
}

ds_result_t ds_clock_now_ns(const ds_clock_t *clock, uint64_t *out_ns)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (out_ns == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out_ns must not be null");
    }
    *out_ns = clock->held_mono_ns;
    return DS_OK_R;
}

ds_result_t ds_clock_wall_ns(const ds_clock_t *clock, int64_t *out_ns,
                             bool *out_set)
{
    if (clock == NULL || out_ns == NULL || out_set == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock, out_ns and out_set must not be null");
    }
    *out_set = clock->held_wall_set;
    *out_ns  = clock->held_wall_ns;
    return DS_OK_R;
}

ds_result_t ds_clock_source_ns(const ds_clock_t *clock, uint64_t *out_ns)
{
    if (clock == NULL || out_ns == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock and out_ns must not be null");
    }
    *out_ns = source_mono_ns(clock);
    return DS_OK_R;
}

ds_result_t ds_clock_set_mode(ds_clock_t *clock, ds_clock_mode_t mode)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (mode != DS_CLOCK_LIVE && mode != DS_CLOCK_MOCK) {
        return DS_ERR_R(DS_ERR_INVAL, "unknown clock mode");
    }
    if (mode == clock->mode) {
        return DS_OK_R;
    }

    if (mode == DS_CLOCK_MOCK) {
        /* [NLFC.5.4]: from 0, the mock clock would run backward from a held
           live sample. */
        if (clock->sampled) {
            return DS_ERR_R(DS_ERR_STATE,
                "cannot switch to the mock clock after the engine has "
                "sampled its clock");
        }
        clock->mock_now_ns   = 0;
        clock->mock_wall_set = false;
        clock->mock_wall_ns  = 0;
    } else {
        clock->live_base_ns = read_monotonic_ns() - clock->mock_now_ns;
    }

    clock->mode = mode;
    return DS_OK_R;
}

ds_result_t ds_clock_set(ds_clock_t *clock, uint64_t now_ns)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (clock->mode != DS_CLOCK_MOCK) {
        return DS_ERR_R(DS_ERR_STATE, "clock_set requires mock mode");
    }
    /* [NTST.3.1] */
    if (clock->sampled && now_ns < clock->mock_now_ns) {
        return DS_ERR_R(DS_ERR_STATE,
            "clock_set below the current monotonic value after the first sample");
    }
    if (now_ns > DS_CLOCK_TOP_NS) {
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "clock_set past the monotonic clock's range");
    }
    clock->mock_now_ns = now_ns;
    return DS_OK_R;
}

ds_result_t ds_clock_advance(ds_clock_t *clock, uint64_t delta_ns)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (clock->mode != DS_CLOCK_MOCK) {
        return DS_ERR_R(DS_ERR_STATE, "clock_advance requires mock mode");
    }
    /* [NTST.3.1]: an advance past a clock's range moves nothing. Only a wall
       value at or above zero can pass the top. Where both would, the wall
       clock's is the refusal named. */
    if (clock->mock_wall_set && clock->mock_wall_ns >= 0
        && delta_ns > (uint64_t) INT64_MAX - (uint64_t) clock->mock_wall_ns) {
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "clock_advance past the wall clock's Time range");
    }
    if (delta_ns > DS_CLOCK_TOP_NS - clock->mock_now_ns) {
        return DS_ERR_R(DS_ERR_TIME_RANGE,
                        "clock_advance past the monotonic clock's range");
    }
    clock->mock_now_ns += delta_ns;
    if (clock->mock_wall_set) clock->mock_wall_ns += (int64_t) delta_ns;
    return DS_OK_R;
}

ds_result_t ds_clock_wall_set(ds_clock_t *clock, int64_t utc_ns)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (clock->mode != DS_CLOCK_MOCK) {
        return DS_ERR_R(DS_ERR_STATE, "wall_clock_set requires mock mode");
    }
    clock->mock_wall_set = true;
    clock->mock_wall_ns  = utc_ns;
    return DS_OK_R;
}

ds_result_t ds_clock_wall_unset(ds_clock_t *clock)
{
    if (clock == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "clock must not be null");
    }
    if (clock->mode != DS_CLOCK_MOCK) {
        return DS_ERR_R(DS_ERR_STATE, "wall clock unset requires mock mode");
    }
    clock->mock_wall_set = false;
    clock->mock_wall_ns  = 0;
    return DS_OK_R;
}

ds_result_t ds_engine_clock_mode(ds_engine_t     *engine,
                                 ds_clock_mode_t *out_mode)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    if (out_mode == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "out_mode must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    *out_mode = engine->clock.mode;
    return DS_OK_R;
}

ds_result_t ds_engine_clock_set_mode(ds_engine_t    *engine,
                                     ds_clock_mode_t mode)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_clock_set_mode(&engine->clock, mode);
}

/* The integrator's read of the source. Not a sample. */
ds_result_t ds_engine_clock_now(ds_engine_t *engine, uint64_t *out_ns)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_clock_source_ns(&engine->clock, out_ns);
}

ds_result_t ds_engine_clock_step(ds_engine_t *engine, ds_clock_step_t step)
{
    ds_clock_reading_t reading;
    ds_clock_read(&engine->clock, &reading);
    return ds_engine_clock_step_at(engine, step, &reading);
}

ds_result_t ds_engine_clock_step_at(ds_engine_t *engine, ds_clock_step_t step,
                                    const ds_clock_reading_t *reading)
{
    /* [NLFC.9.5]: before anything is sampled or recorded. */
    ds_result_t gr =
        ds_engine_nlfc_9_5_first_sample_in_range(engine, reading->mono_ns);
    if (gr.status != DS_OK) return gr;

    bool first  = !engine->clock.sampled;
    bool record = false;
    ds_result_t r = ds_clock_sample(&engine->clock, step, reading, &record);
    if (r.status != DS_OK) return r;

    /* [NLFC.9.4] */
    if (first) ds_cache_resolve_held(&engine->cache, engine->clock.held_mono_ns);

    ds_result_t er = DS_OK_R;
    if (record) {
        er = ds_recorder_emit_tick(engine);
        ds_clock_mark_recorded(&engine->clock);
        /* [NMET.4.1] */
        ds_metric_t tm = {
            .name = "ds.clock.tick_total",
            .kind = DS_METRIC_COUNTER, .value = 1.0,
            .labels = NULL, .n_labels = 0,
        };
        ds_telemetry_emit_metric(engine, &tm);
    }
    /* [LGRA.24.3]: the first step applies the `initial` block, after its TICK and
       before the step's input. DS_ERR_CONTRACT_BREACH from it is a bounds refusal
       of the whole step, already recorded.

       The step's input's TTL override, held on wm.ttl_override_ns, is not the
       block's: the block places only `explicit` facts ([LGRA.24.2]). */
    if (engine->n_initial > 0) {
        const uint64_t input_override = engine->wm.ttl_override_ns;
        engine->wm.ttl_override_ns = 0;
        ds_result_t ar = ds_engine_initial_apply(engine, step);
        engine->wm.ttl_override_ns = input_override;
        if (ar.status != DS_OK) return ar;
    }
    return er;
}

/* The three mock setters are not samples ([NTST.3.3]): no TICK, no record. */
static ds_result_t engine_clock_set_body(ds_engine_t *engine, uint64_t now_ns)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_clock_set(&engine->clock, now_ns);
}

ds_result_t ds_engine_clock_set(ds_engine_t *engine, uint64_t now_ns)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_clock_set_body(engine, now_ns));
}

static ds_result_t engine_clock_advance_body(ds_engine_t *engine,
                                             uint64_t delta_ns)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    ds_result_t r = ds_clock_advance(&engine->clock, delta_ns);
    if (r.status != DS_OK) return r;
    /* [NMET.4.1]: counts the calls, not the samples that observe them. */
    ds_metric_t am = {
        .name = "ds.clock.advance_total",
        .kind = DS_METRIC_COUNTER, .value = 1.0,
        .labels = NULL, .n_labels = 0,
    };
    ds_telemetry_emit_metric(engine, &am);
    return DS_OK_R;
}

ds_result_t ds_engine_clock_advance(ds_engine_t *engine, uint64_t delta_ns)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_clock_advance_body(engine, delta_ns));
}

static ds_result_t engine_wall_clock_set_body(ds_engine_t *engine,
                                              int64_t      utc_ns)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL, "engine must not be null");
    }
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    return ds_clock_wall_set(&engine->clock, utc_ns);
}

ds_result_t ds_engine_wall_clock_set(ds_engine_t *engine, int64_t utc_ns)
{
    ds_api_enter(engine);
    return ds_api_leave(engine, engine_wall_clock_set_body(engine, utc_ns));
}

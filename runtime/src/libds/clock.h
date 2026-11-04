/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * clock.h — the clock module, the engine's sole reader of host time
 * ([IARC.3.11]).
 */
#ifndef LIBDS2_INTERNAL_CLOCK_H
#define LIBDS2_INTERNAL_CLOCK_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"

/*
 * Two clocks, one sample per step ([LTIM.2.8]).
 *
 * The source is what the clock would read now: the platform, or in mock mode
 * the values the test set. The held sample is what the engine read at the last
 * step, and every engine read returns it. Mutations move the source and are not
 * samples ([NTST.3.3]).
 *
 * `wall_set == false` is a wall clock with no value, not a zero: a zero is
 * 1970-01-01.
 */
typedef struct ds_clock {
    ds_clock_mode_t mode;

    /* Subtracted from live reads. */
    uint64_t live_base_ns;

    uint64_t mock_now_ns;
    bool     mock_wall_set;
    int64_t  mock_wall_ns;

    /* Zero and unset before the first sample. */
    uint64_t held_mono_ns;
    bool     held_wall_set;
    int64_t  held_wall_ns;

    /* The last sample put on the trace ([LTIM.2.8.5]). */
    bool     recorded;
    uint64_t rec_mono_ns;
    bool     rec_wall_set;
    int64_t  rec_wall_ns;

    /* After the first sample, the monotonic clock can no longer be set backward
       ([NTST.3.1]) or switched to mock ([NLFC.5.4]). */
    bool     sampled;
} ds_clock_t;

/* What a sample was taken for ([LTIM.2.8.4]). */
typedef enum {
    DS_CLOCK_STEP_INPUT = 0,
    DS_CLOCK_STEP_PUMP  = 1,
} ds_clock_step_t;

/* One reading of the source. A step reads the source once: a check that must
   judge a step's sample before the step is taken ([RFCS.6.7], [NLFC.9.5]) judges
   this reading, and the step then holds it. */
typedef struct ds_clock_reading {
    uint64_t mono_ns;
    bool     wall_set;
    int64_t  wall_ns;
} ds_clock_reading_t;

ds_result_t ds_clock_init(ds_clock_t *clock);

/* Read both clocks of the source. Not a sample. */
void        ds_clock_read(const ds_clock_t *clock, ds_clock_reading_t *out);

/* Take `reading` into the held sample. Sets *out_record when the sample must go
   on the trace ([LTIM.2.8.5]): the caller records it, then calls
   ds_clock_mark_recorded, before the record of the step. */
ds_result_t ds_clock_sample(ds_clock_t *clock, ds_clock_step_t step,
                            const ds_clock_reading_t *reading,
                            bool *out_record);
void        ds_clock_mark_recorded(ds_clock_t *clock);

/* The held monotonic sample. */
ds_result_t ds_clock_now_ns(const ds_clock_t *clock, uint64_t *out_ns);

/* The held wall sample, UTC ns since the Unix epoch. */
ds_result_t ds_clock_wall_ns(const ds_clock_t *clock, int64_t *out_ns,
                             bool *out_set);

/* The SOURCE's current monotonic value: what ds_engine_clock_now reports
   to an integrator. Not a sample, and nothing in the engine calls it. */
ds_result_t ds_clock_source_ns(const ds_clock_t *clock, uint64_t *out_ns);

/* The platform itself, read now, for a standalone rete engine, which has no DS
   engine clock. The wall read is false when it has no value. */
uint64_t ds_clock_platform_mono_ns(void);
bool     ds_clock_platform_wall_ns(int64_t *out_utc_ns);

/* LIVE -> MOCK starts the mock monotonic clock at 0 and leaves the mock wall
   clock unset; refused after the first sample. MOCK -> LIVE continues the
   monotonic clock. */
ds_result_t ds_clock_set_mode(ds_clock_t *clock, ds_clock_mode_t mode);

/* Mock-only. Refused below the current value after the first sample. */
ds_result_t ds_clock_set(ds_clock_t *clock, uint64_t now_ns);

/* Mock-only: advance the monotonic clock, and a set wall clock by the same
   duration ([NTST.3.1]). */
ds_result_t ds_clock_advance(ds_clock_t *clock, uint64_t delta_ns);

/* Mock-only. Any instant, earlier or later. */
ds_result_t ds_clock_wall_set(ds_clock_t *clock, int64_t utc_ns);

/* Mock-only, and replay's alone ([RFCS.10.5]): return the wall clock to no
   value. */
ds_result_t ds_clock_wall_unset(ds_clock_t *clock);

/* The engine's step: sample, and record the sample when it must be
   ([LTIM.2.8.5]). Called first by every input entry point and by the pump. */
ds_result_t ds_engine_clock_step(ds_engine_t *engine, ds_clock_step_t step);

/* The same step, taking `reading` as its sample, for an entry point that judged
   the sample before the step (wm.c's host assert, [RFCS.6.7]). */
ds_result_t ds_engine_clock_step_at(ds_engine_t *engine, ds_clock_step_t step,
                                    const ds_clock_reading_t *reading);

#endif /* LIBDS2_INTERNAL_CLOCK_H */

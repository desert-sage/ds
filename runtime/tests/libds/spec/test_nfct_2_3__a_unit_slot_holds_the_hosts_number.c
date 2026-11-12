/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NFCT.2.3]
 * "The number a host gives a slot typed by a unit or a dimension is the slot's
 * stored number ([LUNI.7.6])", and the number a host reads back is that
 * number: libds converts nothing at the boundary.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_assert placing each value as given, and
 * ds_fact_get_slot on the fact it returns, read through libds.h. A host read
 * has no surface in a conformance vector ([RCTS.1.2.26]), which is why this is
 * a C test; logical/LUNI.7.6_a_hosts_number_is_the_stored_number holds the
 * assert half on both runtimes.
 *
 * `Reading.temp` is a `celsius` slot (dimension `temperature`, Float kelvin)
 * and `Reading.d` a `millisecond` slot (dimension `time`, Int nanoseconds).
 *
 *   (a) The host asserts `temp` DS_SLOT_FLOAT 300.0 and `d` DS_SLOT_INT 1500.
 *       ds_fact_get_slot reads `temp` as DS_SLOT_FLOAT 300.0 and `d` as
 *       DS_SLOT_INT 1500. A read that converted to the slot's unit gives
 *       26.85 and 0.0015 (or 0).
 *   (b) The engine holds 300.0 as kelvin: `below`, `r.temp < 27_celsius`
 *       (300.15 K), fires on the pump, and `nanos`, `r.d == 1500_ns`, fires.
 *       An assert that took 300.0 as Celsius holds 573.15 K and `below` does
 *       not fire; one that took 1500 as milliseconds and `nanos` does not.
 */
#include "spec_common.h"

#include <stdbool.h>

static const char *PROGRAM =
    "unit celsius: temperature = x + 273.15\n"
    "\n"
    "schema Reading scope logical:\n"
    "    id: String key\n"
    "    temp: celsius mutable\n"
    "    d: millisecond mutable\n"
    "\n"
    "rule below:\n"
    "    Reading r where r.temp < 27_celsius\n"
    "->\n"
    "    log info \"below\"\n"
    "\n"
    "rule nanos:\n"
    "    Reading r where r.d == 1500_ns\n"
    "->\n"
    "    log info \"nanos\"\n";

enum { S_ID, S_TEMP, S_D };

static ds_result_t count_logs(ds_engine_t *engine, const ds_stream_ev_t *ev,
                              void *user)
{
    (void) engine;
    if (ev->kind == DS_EV_ACTION_LOG) (*(int *) user)++;
    return DS_OK_R;
}

int main(void)
{
    int logs = 0;
    ds_engine_t *e = NULL;
    const ds_schema_t *reading = NULL;
    ds_fact_t *fact = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("find Reading", ds_engine_schema_find(e, "Reading", &reading));
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, count_logs, &logs));

    ds_slot_value_t v[3];
    memset(v, 0, sizeof v);
    v[S_ID].kind   = DS_SLOT_STRING; v[S_ID].v.s   = "a";
    v[S_TEMP].kind = DS_SLOT_FLOAT;  v[S_TEMP].v.f = 300.0;
    v[S_D].kind    = DS_SLOT_INT;    v[S_D].v.i    = 1500;
    EXPECT_OK("(a) assert", ds_engine_assert(e, reading, v, 3, &fact));
    if (fact == NULL) {
        fprintf(stderr, "FAIL: (a) the assert returned no fact\n");
        return 1;
    }

    ds_slot_value_t got;
    memset(&got, 0, sizeof got);
    EXPECT_OK("(a) read temp", ds_fact_get_slot(fact, S_TEMP, NULL, &got));
    if (got.kind != DS_SLOT_FLOAT || got.v.f != 300.0) {
        fprintf(stderr, "FAIL: (a) temp reads kind %d value %.17g, want "
                "DS_SLOT_FLOAT 300.0\n", (int) got.kind, got.v.f);
        return 1;
    }
    memset(&got, 0, sizeof got);
    EXPECT_OK("(a) read d", ds_fact_get_slot(fact, S_D, NULL, &got));
    if (got.kind != DS_SLOT_INT || got.v.i != 1500) {
        fprintf(stderr, "FAIL: (a) d reads kind %d value %lld, want "
                "DS_SLOT_INT 1500\n", (int) got.kind, (long long) got.v.i);
        return 1;
    }

    EXPECT_OK("(b) pump", ds_engine_pump(e));
    if (logs != 2) {
        fprintf(stderr, "FAIL: (b) %d of `below` and `nanos` fired, want both: "
                "the engine does not hold 300 K and 1500 ns\n", logs);
        return 1;
    }

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nfct_2_3__a_unit_slot_holds_the_hosts_number: OK\n");
    return 0;
}

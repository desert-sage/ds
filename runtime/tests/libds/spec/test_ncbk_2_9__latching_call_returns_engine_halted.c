/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.2.9]
 * The public call during which the engine raises an EngineError returns
 * DS_ERR_ENGINE_HALTED, ahead of any other status it would have returned.
 *
 * The EngineError comes from an artefact that lies (spec_tamper.h): slot
 * `lied` is compiled as Int and declared String in the artefact, so reading
 * it as an Int is ENGINE_FAULT_ARTEFACT_LIED.
 *
 * THE PATH: ds_engine_pump / ds_engine_assert -> the faulting evaluation
 * (rete/eval.c) -> recorder_emit_fault, which sets the latch -> ds_api_leave,
 * which at the outermost call reports a halt the call raised
 * ([STYL.5.10.8]).
 *
 *   control. The same program, unedited: the pump is DS_OK and the engine is
 *      not halted. So the halts below are the lie's.
 *   (a) The pump that fires the lying action returns DS_ERR_ENGINE_HALTED, and
 *       ds_engine_halted reports ARTEFACT_LIED ([NCBK.2.11]).
 *   (b) The same pump with a stream callback that fails every event still
 *       returns DS_ERR_ENGINE_HALTED: the halt takes precedence over the sink's
 *       status ([NCBK.1.5]).
 *   (c) After (a), the next assert is refused with DS_ERR_ENGINE_HALTED.
 *   (d) An assert whose own propagation raises the EngineError, through a
 *       `where` evaluated as the fact joins, returns DS_ERR_ENGINE_HALTED.
 */
#include "spec_common.h"
#include "spec_tamper.h"

#include <stdbool.h>

/* ---- the programs ------------------------------------------------------ */

/* The lie is read when `halt_at_fire` fires: in a pump. */
static const char *AT_FIRE =
    "schema P scope logical:\n"
    "    id: Int key\n"
    "    lied: Int mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    id: Int key\n"
    "    v: Int mutable\n"
    "\n"
    "rule halt_at_fire:\n"
    "    P p\n"
    "->\n"
    "    emit Out logical id: p.id v: p.lied + 1\n";

/* The lie is read by a `where` that names the binding, a join test evaluated
   as the fact joins: in the assert's own propagation ([LERR.9.7]). */
static const char *AT_JOIN =
    "schema P scope logical:\n"
    "    id: Int key\n"
    "    lied: Int mutable\n"
    "\n"
    "rule halt_at_join:\n"
    "    P p where p.lied + 1 > 0\n"
    "->\n"
    "    log info \"never\"\n";

/* A fresh engine with `src` compiled, lied about when `lying`, and loaded. */
static int open_engine(const char *src, bool lying, ds_engine_t **out,
                       const ds_schema_t **out_p)
{
    *out = NULL;
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(src, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile", r);
    if (lying && lie(dsc, len)) { free(dsc); return 1; }
    ds_engine_t *e = NULL;
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine_new", r); }
    r = ds_engine_load_dsc(e, dsc, len);
    free(dsc);
    if (r.status != DS_OK) { ds_engine_free(e); return spec_fail("load_dsc", r); }
    r = ds_engine_schema_find(e, "P", out_p);
    if (r.status != DS_OK || *out_p == NULL) {
        ds_engine_free(e);
        return spec_fail("find P", r);
    }
    *out = e;
    return 0;
}

/* Assert P(id, lied), `lied` a String under the lie and an Int without it. */
static ds_result_t assert_p(ds_engine_t *e, const ds_schema_t *p, int64_t id,
                            bool lying)
{
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = id;
    if (lying) {
        v[1].kind = DS_SLOT_STRING;
        v[1].v.s  = "x";
    } else {
        v[1].kind = DS_SLOT_INT;
        v[1].v.i  = 1;
    }
    return ds_engine_assert(e, p, v, 2, NULL);
}

static int expect_halted_on_artefact_lied(ds_engine_t *e, const char *what)
{
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    ds_result_t r = ds_engine_halted(e, &halted, &fault);
    EXPECT_OK("ds_engine_halted", r);
    if (!halted || fault != DS_ENGINE_FAULT_ARTEFACT_LIED) {
        fprintf(stderr, "FAIL: %s: halted=%d fault=%d, want halted on "
                        "ARTEFACT_LIED\n", what, (int) halted, (int) fault);
        return 1;
    }
    return 0;
}

static ds_result_t failing_sink(ds_engine_t *engine, const ds_stream_ev_t *ev,
                                void *user)
{
    (void) engine; (void) ev;
    (*(int *) user)++;
    return DS_ERR_R(DS_ERR_INVAL, "this sink fails every event");
}

/* ---- the cases --------------------------------------------------------- */

static int test_control_without_the_lie(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *p = NULL;
    if (open_engine(AT_FIRE, false, &e, &p)) return 1;
    int rc = 0;
    ds_result_t r = assert_p(e, p, 1, false);
    if (r.status != DS_OK) rc = spec_fail("control: assert", r);
    r = ds_engine_pump(e);
    if (!rc && r.status != DS_OK) rc = spec_fail("control: the pump is DS_OK", r);
    bool halted = true;
    if (!rc && (ds_engine_halted(e, &halted, NULL).status != DS_OK || halted)) {
        fprintf(stderr, "FAIL: control: the unedited program halted\n");
        rc = 1;
    }
    ds_engine_free(e);
    return rc;
}

/* (a) and (c). */
static int test_the_halting_pump_returns_engine_halted(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *p = NULL;
    if (open_engine(AT_FIRE, true, &e, &p)) return 1;
    int rc = 0;
    ds_result_t r = assert_p(e, p, 1, true);
    if (r.status != DS_OK) {
        rc = spec_fail("(a) premise: the assert is admitted; the lie is read "
                       "at fire time", r);
        goto done;
    }
    r = ds_engine_pump(e);
    if (r.status != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: (a) the pump that fires the lying action: want "
                        "DS_ERR_ENGINE_HALTED, got %d (%s)\n",
                r.status, r.detail ? r.detail : "(null)");
        rc = 1;
        goto done;
    }
    if (expect_halted_on_artefact_lied(e, "(a) after the pump")) { rc = 1; goto done; }

    r = assert_p(e, p, 2, true);
    if (r.status != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: (c) the next assert: want DS_ERR_ENGINE_HALTED, "
                        "got %d\n", r.status);
        rc = 1;
    }
done:
    ds_engine_free(e);
    return rc;
}

/* (b). */
static int test_the_halt_takes_precedence_over_the_stream_status(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *p = NULL;
    if (open_engine(AT_FIRE, true, &e, &p)) return 1;
    int rc = 0;
    ds_result_t r = assert_p(e, p, 1, true);
    if (r.status != DS_OK) { rc = spec_fail("(b) premise: assert", r); goto done; }
    /* After the assert, so the assert's own events do not fail it. */
    int delivered = 0;
    r = ds_engine_set_stream_callback(e, failing_sink, &delivered);
    if (r.status != DS_OK) { rc = spec_fail("(b) set_stream_callback", r); goto done; }
    r = ds_engine_pump(e);
    if (delivered == 0) {
        fprintf(stderr, "FAIL: (b) premise: the failing sink saw no event\n");
        rc = 1;
        goto done;
    }
    if (r.status != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: (b) with a sink failing every event: want "
                        "DS_ERR_ENGINE_HALTED, got %d (%s)\n",
                r.status, r.detail ? r.detail : "(null)");
        rc = 1;
        goto done;
    }
    if (expect_halted_on_artefact_lied(e, "(b) after the pump")) rc = 1;
done:
    ds_engine_free(e);
    return rc;
}

/* (d). */
static int test_an_assert_whose_propagation_halts_returns_engine_halted(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *p = NULL;
    if (open_engine(AT_JOIN, true, &e, &p)) return 1;
    int rc = 0;
    ds_result_t r = assert_p(e, p, 1, true);
    if (r.status != DS_ERR_ENGINE_HALTED) {
        fprintf(stderr, "FAIL: (d) an assert whose join raises the EngineError: "
                        "want DS_ERR_ENGINE_HALTED, got %d (%s)\n",
                r.status, r.detail ? r.detail : "(null)");
        rc = 1;
        goto done;
    }
    if (expect_halted_on_artefact_lied(e, "(d) after the assert")) rc = 1;
done:
    ds_engine_free(e);
    return rc;
}

int main(void)
{
    int failed = 0;
    failed |= test_control_without_the_lie();
    failed |= test_the_halting_pump_returns_engine_halted();
    failed |= test_the_halt_takes_precedence_over_the_stream_status();
    failed |= test_an_assert_whose_propagation_halts_returns_engine_halted();
    if (failed) {
        fprintf(stderr, "test_ncbk_2_9__latching_call_returns_engine_halted: FAILED\n");
        return 1;
    }
    printf("test_ncbk_2_9__latching_call_returns_engine_halted: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.2.5]
 * "A call from inside a callback is refused as [RARC.13.16] states":
 * ds_engine_next_deadline_ns called from the stream callback, on the engine
 * that invoked it, returns DS_ERR_STATE. The callback calls it on every event
 * of an assert of `Write` and the pump that writes the cache entry, and keeps
 * each status.
 *
 *   (a) The callback ran, and every call it made was DS_ERR_STATE.
 *   (b) The control: the same call from outside any callback, after the pump,
 *       answers DS_OK and the entry's 10 s, so the refusals are the
 *       re-entry's.
 *
 * THE PATH ([STYL.5.10.8]): ds_engine_next_deadline_ns (engine.c), through
 * DS_ENGINE_REFUSE_IF_HALTED's re-entry check.
 */
#include "spec_deadline.h"

typedef struct {
    int calls;
    int refused;
    ds_status_t other;
} probe_t;

static ds_result_t probe(ds_engine_t *engine, const ds_stream_ev_t *ev,
                         void *user)
{
    (void) ev;
    probe_t *p = user;
    uint64_t ns = 0;
    bool has = false;
    ds_result_t r = ds_engine_next_deadline_ns(engine, &ns, &has);
    p->calls++;
    if (r.status == DS_ERR_STATE) p->refused++;
    else p->other = r.status;
    return DS_OK_R;
}

int main(void)
{
    probe_t p;
    memset(&p, 0, sizeof p);
    ds_engine_t *e = NULL;
    if (dl_engine(&e, dl_program())) return 1;
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, probe, &p));
    if (dl_assert(e, "Write", 1, NULL)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));

    if (p.calls == 0) return dl_fail("(a)", "premise: the stream callback never ran");
    if (p.refused != p.calls) {
        fprintf(stderr, "FAIL: (a) %d of %d calls from the callback were "
                "DS_ERR_STATE; another returned %d\n", p.refused, p.calls,
                (int) p.other);
        return 1;
    }

    EXPECT_OK("stream off", ds_engine_set_stream_callback(e, NULL, NULL));
    if (dl_expect("(b) the control, outside a callback", e, true, 10 * DL_SEC))
        return 1;

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nlfc_2_5__refused_from_a_callback: OK\n");
    return 0;
}

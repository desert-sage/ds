/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Smoke test for libds.a coherence — invoked during the
 * libds-registry image build. References every symbol that
 * the integration's build needs from the merged archive. If any
 * symbol is missing, the link fails and `docker build` aborts
 * before the registry push.
 *
 * History: at `ds-libds:0.1.0` and `0.3.0` the merge step in
 * libds-registry.Dockerfile clobbered our `engine.o` with CLIPS's
 * — both archives shipped an `engine.o`, and the previous merge
 * extracted both into the same scratch dir, so `*.o` only saw the
 * second one. Six symbols silently became U-only in
 * `libds.a` and the integration's link broke. Fixed at fe3244d
 * (per-archive subdir extraction); this smoke binary makes the
 * regression unrepeatable — any future archive-merge mistake that
 * drops one of these symbols fails the docker build immediately
 * instead of slipping through to the published image.
 *
 * Maintenance: if a future libds caller needs a new symbol from
 * the archive, add it here as well so the gate covers it.
 */

extern void ds_engine_set_pending();
extern void ds_engine_take_pending();
extern void ds_engine_find_rule_meta();
extern void ds_engine_free();

int main(void)
{
    /* Take each address through `volatile` so the optimiser can't
     * elide the references and weaken the link-time check. */
    volatile void *syms[] = {
        (void *)ds_engine_set_pending,
        (void *)ds_engine_take_pending,
        (void *)ds_engine_find_rule_meta,
        (void *)ds_engine_free,
    };
    return syms[0] != (void *)0 ? 0 : 1;
}

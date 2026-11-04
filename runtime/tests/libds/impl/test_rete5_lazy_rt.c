/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The lazy realtime handshake: a `+constspace` CapabilityInfo (LCSP.6.2,
 * loader.c handle_capb) arms pending_rt at load, and the first
 * ds_engine_set_wm_max engages realtime. Without it, nothing does.
 */
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "dsc/loader.h"
#include "test_ds_version.h"  /* [LDET.1.10] ds_test_accepted_version */

/* Internal engine struct for inspecting pending_rt / rt_mode / pools_ready. */
#include "engine.h"
#include "rete/engine.h"
#include "dsc/pbf_writer.h"   /* fixtures frame through the production writer */
#include "sha256.h"           /* [RDSC.3.6] — the fixture is sealed */

#define MAGIC_LEN 4

typedef struct { uint8_t *data; size_t len, cap; } buf_t;

static void buf_init(buf_t *b) { b->data = NULL; b->len = b->cap = 0; }
static void buf_free(buf_t *b) { free(b->data); buf_init(b); }

static int buf_append(buf_t *b, const void *src, size_t n) {
    if (b->len + n > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 64;
        while (nc < b->len + n) nc *= 2;
        uint8_t *nb = realloc(b->data, nc);
        if (!nb) return -1;
        b->data = nb; b->cap = nc;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 0;
}

static int buf_append_atom(buf_t *b, uint32_t field,
                            const uint8_t *body, size_t body_len) {
    size_t   total = 0;
    uint8_t *frame;
    int      rc;

    if (!ds_pbf_lookup(field)) return -1;
    total = ds_pbf_framed_size(field, body_len);
    if (total == 0) return -1;
    frame = malloc(total);
    if (frame == NULL) return -1;
    if (!ds_pbf_frame_atom(field, body, body_len, frame, total, &total)) {
        free(frame);
        return -1;
    }
    rc = buf_append(b, frame, total);
    free(frame);
    return rc;
}

/*
 * Build a minimal valid DSC: DscHeader header + optional CapabilityInfo carrying the
 * `+constspace` capability. No rule-network atom is required (RDSC.4.2 —
 * the loader accepts Rete-only / atom-only DSCs).
 */
static int build_minimal_dsc(buf_t *out, bool include_constspace_cap) {
    buf_init(out);

    /* DscHeader field 3 (0x1a): compiler_version, this build's own DS
       version, which [LDET.1.10] makes the load gate. */
    uint8_t dsco_body[256];
    size_t dsco_len = 0;
    size_t sha_at = 0;   /* where field 7's 32 bytes sit in the body */
    {
        const char *ver = ds_test_accepted_version();
        const size_t vlen = strlen(ver);
        /* A one-byte length prefix: a varint below 128 is one byte, and this
           breaks loudly (a decode failure, not a wrong answer) if a version
           string ever exceeds that. */
        if (vlen > 127u) return -1;
        if (2u + vlen + 2u + 32u + 2u + 32u > sizeof(dsco_body))
            return -1;
        dsco_body[dsco_len++] = 0x1a;
        dsco_body[dsco_len++] = (uint8_t) vlen;
        memcpy(dsco_body + dsco_len, ver, vlen); dsco_len += vlen;
        /* field 7 (0x3a): dsc_sha256, 32 zero bytes until sealed below. */
        dsco_body[dsco_len++] = 0x3a;
        dsco_body[dsco_len++] = 32u;
        sha_at = dsco_len;
        memset(dsco_body + dsco_len, 0, 32u); dsco_len += 32u;
        /* field 10 (0x52): dialect_def_sha256, 32 bytes, which [RDSC.3.7]
           requires of every header. Only its length is checked at load. */
        dsco_body[dsco_len++] = 0x52;
        dsco_body[dsco_len++] = 32u;
        memset(dsco_body + dsco_len, 0xD5, 32u); dsco_len += 32u;
    }
    if (buf_append_atom(out, DS_ATOM_DSC_HEADER, dsco_body, dsco_len)) return -1;
    /* DscHeader is the first atom, so its body starts after its own frame prefix. */
    sha_at += ds_pbf_framed_size(DS_ATOM_DSC_HEADER, dsco_len) - dsco_len;

    /* CapabilityInfo, which every artefact carries ([RDSC.16.2.4]): `enabled` (field 2)
     * is a packed `repeated Capability`, and `constspace` is 2. It is the
     * lazy-RT-arming setting (unlike `realtime`, it needs no RealtimeContract atom).
     * Without it the body is empty: nothing enabled, nothing required. */
    static const uint8_t capb_constspace[] = {
        0x12,                       /* field 2, wire type 2 (packed) */
        1,                          /* one value */
        2                           /* CAPABILITY_CONSTSPACE */
    };
    static const uint8_t capb_empty[1] = { 0 };
    if (include_constspace_cap
            ? buf_append_atom(out, DS_ATOM_CAPABILITY_INFO, capb_constspace, sizeof(capb_constspace))
            : buf_append_atom(out, DS_ATOM_CAPABILITY_INFO, capb_empty, 0))
        return -1;
    /* [RDSC.3.6] — seal as the compiler does: hash the whole artefact with
       field 7 zeroed, write the digest in. The loader refuses a mismatch. Last,
       so the hash covers the CapabilityInfo atom too. */
    {
        uint8_t digest[32];
        ds_sha256(out->data, out->len, digest);
        memcpy(out->data + sha_at, digest, 32u);
    }
    return 0;
}

static int expect(const char *label, int cond) {
    if (!cond) { fprintf(stderr, "FAIL: %s\n", label); return 1; }
    return 0;
}

/*
 * Lazy path: load DSC with a +constspace CapabilityInfo (no schemas) → pending_rt
 * armed, rt_mode still off. Then ds_engine_set_wm_max(100) engages RT:
 * pending_rt cleared, rt_mode + pools_ready set, N_max recorded.
 */
static int test_lazy_rt_init(void) {
    buf_t dsc; build_minimal_dsc(&dsc, true);
    ds_engine_t *e = NULL; ds_engine_new(NULL, &e);
    int r = 0;

    r |= expect("load ok",
        ds_engine_load_dsc(e, dsc.data, dsc.len).status == DS_OK);
    r |= expect("pending_rt armed after +constspace load",
        e->rete_engine && e->rete_engine->pending_rt == true);
    r |= expect("rt_mode not yet set",
        e->rete_engine && !e->rete_engine->rt_mode);

    r |= expect("set_wm_max ok",
        ds_engine_set_wm_max(e, 100).status == DS_OK);

    r |= expect("pending_rt cleared",  e->rete_engine && !e->rete_engine->pending_rt);
    r |= expect("rt_mode set",         e->rete_engine && e->rete_engine->rt_mode);
    r |= expect("pools_ready",         e->rete_engine && e->rete_engine->pools_ready);
    r |= expect("wm_max_facts == 100", e->rete_engine && e->rete_engine->wm_max_facts == 100);

    ds_engine_free(e);
    buf_free(&dsc);
    return r;
}

/*
 * No-cap DSC: loads normally, no lazy handshake armed, rt_mode stays false.
 */
static int test_no_cap_no_rt_mode(void) {
    buf_t dsc; build_minimal_dsc(&dsc, false);
    ds_engine_t *e = NULL; ds_engine_new(NULL, &e);
    int r = 0;

    r |= expect("load ok",
        ds_engine_load_dsc(e, dsc.data, dsc.len).status == DS_OK);
    r |= expect("pending_rt not armed",
        e->rete_engine && !e->rete_engine->pending_rt);
    r |= expect("rt_mode stays false",
        e->rete_engine && !e->rete_engine->rt_mode);

    ds_engine_free(e);
    buf_free(&dsc);
    return r;
}

/*
 * [NLFC.10.3] — a sizing call never selects a strategy. Schemas registered and
 * N_max set, with no artefact asking for constspace: the engine stays out of
 * RT mode, and N_max is advisory (NRTM.3.1), so wm_max_facts is not armed
 * either.
 */
static int test_nlfc_10_3__schemas_and_wm_max_do_not_engage_rt(void) {
    ds_engine_t *e = NULL; ds_engine_new(NULL, &e);
    int r = 0;
    static const ds_slot_desc_t slots[1] = {
        { .name = "v", .type = DS_SLOT_TYPE_INT }
    };

    r |= expect("register_schema ok",
        ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_TTL, 1000u,
                                  slots, 1, NULL).status == DS_OK);
    r |= expect("set_wm_max ok",
        ds_engine_set_wm_max(e, 64).status == DS_OK);
    r |= expect("rt_mode stays false with schemas loaded",
        e->rete_engine && !e->rete_engine->rt_mode);
    r |= expect("wm_max_facts not armed (advisory, NRTM.3.1)",
        e->rete_engine && e->rete_engine->wm_max_facts == 0);

    ds_engine_free(e);
    return r;
}

/*
 * set_wm_max with no pending realtime contract: N_max is advisory
 * (NRTM.3.1), so the call is accepted and arms nothing -- no RT init, and
 * not the Rete engine's wm_max_facts either, which would refuse an assert
 * past it. With schemas loaded the answer is the same; a loaded program is
 * not a trigger (test_nrtm_3_1_wm_max_advisory covers that case).
 */
static int test_set_wm_max_no_pending(void) {
    ds_engine_t *e = NULL; ds_engine_new(NULL, &e);
    int r = 0;

    r |= expect("set_wm_max ok",
        ds_engine_set_wm_max(e, 64).status == DS_OK);
    r |= expect("pending_rt not armed",  e->rete_engine && !e->rete_engine->pending_rt);
    r |= expect("rt_mode stays false",
        e->rete_engine && !e->rete_engine->rt_mode);
    r |= expect("wm_max_facts not armed (advisory, NRTM.3.1)",
        e->rete_engine && e->rete_engine->wm_max_facts == 0);

    ds_engine_free(e);
    return r;
}

int main(void) {
    int failed = 0;
    failed |= test_lazy_rt_init();
    failed |= test_no_cap_no_rt_mode();
    failed |= test_set_wm_max_no_pending();
    failed |= test_nlfc_10_3__schemas_and_wm_max_do_not_engage_rt();
    if (!failed) printf("OK\n");
    return failed;
}

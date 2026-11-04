/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The contract dump returns the loaded contract's canonical (RBND.4b) bytes in
 * a buffer the caller owns and frees with ds_free. Realtime declares no entry
 * point in this edition ([NRTM.9.1]), so the cases drive the internal body,
 * `ds_contract_dump_canonical_body` (dsc/dsrt_loader.h): the bytes match
 * ds_dsrt_canonical_bytes, no contract is DS_ERR_CONTRACT_MISSING with nothing
 * allocated, and a NULL argument is DS_ERR_INVAL with the others cleared. The
 * contract is set on the engine directly, since loading one needs a compiled
 * realtime artefact.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "dsc/dsrt_loader.h"
#include "engine.h"       /* ds_engine.rete_engine — the contract is set directly */
#include "rete/engine.h"  /* has_contract and the contract_* caps */

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static ds_engine_t *new_engine(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return NULL;
    return e;
}

static void test_the_dump_is_the_canonical_bytes(void)
{
    ds_engine_t *e = new_engine();
    CHECK(e != NULL, "ds_engine_new");
    if (!e) return;
    e->rete_engine->has_contract                = true;
    e->rete_engine->contract_wm_max             = 64;
    e->rete_engine->contract_agenda_cap         = 32;
    e->rete_engine->contract_max_fires_per_pump = 16;
    e->rete_engine->contract_pump_wcet_ns       = 250000;

    size_t need = ds_dsrt_canonical_bytes(e, NULL, 0);
    CHECK(need > 0, "the reference serialization is not empty");
    char *want = malloc(need + 1);
    CHECK(want != NULL, "malloc");
    if (want) (void)ds_dsrt_canonical_bytes(e, want, need + 1);

    char *buf = NULL;
    size_t len = 0;
    ds_result_t r = ds_contract_dump_canonical_body(e, &buf, &len);
    CHECK(r.status == DS_OK, "the dump succeeds with a contract loaded");
    CHECK(buf != NULL, "the dump returns a buffer");
    CHECK(len == need, "its length is the serialization's, NUL excluded");
    if (buf && want && len == need) {
        CHECK(memcmp(buf, want, need) == 0, "its bytes are the canonical bytes");
        CHECK(buf[len] == '\0', "a NUL follows the bytes");
    }
    ds_free(buf);
    free(want);

    /* Two dumps of one engine agree: the call reads, it does not consume. */
    char *a = NULL, *b = NULL;
    size_t la = 0, lb = 0;
    CHECK(ds_contract_dump_canonical_body(e, &a, &la).status == DS_OK
              && ds_contract_dump_canonical_body(e, &b, &lb).status == DS_OK,
          "two dumps both succeed");
    CHECK(a && b && la == lb && memcmp(a, b, la) == 0,
          "and give the same bytes");
    ds_free(a);
    ds_free(b);

    e->rete_engine->has_contract = false;
    ds_engine_free(e);
}

static void test_no_contract_allocates_nothing(void)
{
    ds_engine_t *e = new_engine();
    CHECK(e != NULL, "ds_engine_new");
    if (!e) return;
    char *buf = (char *) "sentinel";
    size_t len = 99;
    ds_result_t r = ds_contract_dump_canonical_body(e, &buf, &len);
    CHECK(r.status == DS_ERR_CONTRACT_MISSING, "no contract is CONTRACT_MISSING");
    CHECK(buf == NULL, "and the buffer comes back NULL");
    CHECK(len == 0, "and the length 0");
    ds_engine_free(e);
}

static void test_null_arguments(void)
{
    ds_engine_t *e = new_engine();
    CHECK(e != NULL, "ds_engine_new");
    if (!e) return;
    char *buf = (char *) "sentinel";
    size_t len = 99;
    CHECK(ds_contract_dump_canonical_body(NULL, &buf, &len).status == DS_ERR_INVAL,
          "a NULL engine is INVAL");
    CHECK(buf == NULL && len == 0, "and the out-pointers are cleared");
    len = 99;
    CHECK(ds_contract_dump_canonical_body(e, NULL, &len).status == DS_ERR_INVAL,
          "a NULL buffer pointer is INVAL");
    CHECK(len == 0, "and the length is cleared");
    buf = (char *) "sentinel";
    CHECK(ds_contract_dump_canonical_body(e, &buf, NULL).status == DS_ERR_INVAL,
          "a NULL length pointer is INVAL");
    CHECK(buf == NULL, "and the buffer is cleared");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_nrtm_6_3_contract_dump ===\n");
    test_the_dump_is_the_canonical_bytes();
    test_no_contract_allocates_nothing();
    test_null_arguments();
    if (failures) {
        fprintf(stderr, "test_nrtm_6_3_contract_dump: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("=== test_nrtm_6_3_contract_dump: ALL PASSED ===\n");
    return 0;
}

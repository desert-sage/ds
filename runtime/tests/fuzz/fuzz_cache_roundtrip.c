/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_cache_roundtrip.c -- coverage-guided fuzzing of libds's engine-owned
 * cache through its public API. A value seeded with ds_engine_cache_seed
 * ([LSTO.4.5.2]) comes from storage outside the engine, so it is untrusted.
 * The engine stores a value as its canonical text and re-reads that text, by
 * strlen, wherever a rule reads or writes the cache; those re-reads are what
 * this target reaches.
 *
 * Per input, through libds.h ([STYL.5.10.8]): a fresh engine holding
 * cache_roundtrip.ds (named by DS_FUZZ_CACHE_DSC); ds_engine_cache_seed of
 * the input's tree under the input's key; ds_engine_assert of a Probe naming
 * that key; ds_engine_pump, whose `copy` firing reads the key with `cached()`
 * (adapter_ds_cache_get) and writes it under "out" (adapter_ds_cache_set,
 * bridge_cache_set, the set callback).
 *
 * THE INPUT. Its first byte is the key's length L, at most 32; the next L
 * bytes, each folded into [a-z0-9_], are the key; the rest is JSON text,
 * parsed with ds_json_parse. Text the parser refuses ends the input
 * (fuzz_json_text owns that). The key is folded so the input's variety goes
 * into the value.
 *
 * WHAT IT ASSERTS, each a trap:
 *
 *   1. THE SEED IS DOCUMENTED. ds_engine_cache_seed answers DS_OK, or
 *      DS_ERR_CONTRACT_BREACH for a cap. Never DS_ERR_JSON_NONFINITE: the tree
 *      is ds_json_parse's, and a parsed tree holds no non-finite Float
 *      ([LGRA.5.8.10]; fuzz_json_text holds that), so that status here is a
 *      failure like any other undocumented one.
 *   2. THE VALUE COMES BACK. After a pump, the set callback saw "out" exactly
 *      once, with a String whose bytes are ds_json_serialize's canonical text
 *      of the seeded tree, so `cached()` handed back exactly what was stored.
 *      Except where that text is over DS_JSON_MAX_STRING_BYTES: then the
 *      String cannot be a cache value, `copy` is abandoned with a
 *      NOT_REPRESENTABLE ComputationError ([LGRA.5.8.6]), and the callback
 *      sees nothing.
 *   3. THE PUMP IS CLEAN. ds_engine_assert and ds_engine_pump answer DS_OK.
 *
 * The counts are printed at exit and read by the gate, which refuses a
 * REPLAY none of whose seeds came back.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#define FAIL(why) do {                                          \
        fprintf(stderr, "fuzz_cache_roundtrip: %s\n", (why));   \
        __builtin_trap();                                       \
    } while (0)

#define MAX_KEY 32u

static uint8_t *program;
static size_t   program_len;

/* Counted over the inputs judged: those whose text parsed. */
static unsigned long judged, seeded, came_back, over_limit;

static void report_judged(void)
{
    fprintf(stderr, "fuzz_cache_roundtrip: judged %lu input(s): %lu seeded, "
                    "%lu came back, %lu over the string limit\n",
            judged, seeded, came_back, over_limit);
}

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    uint8_t *p = malloc(n ? (size_t) n : 1u);
    if (p != NULL && fread(p, 1, (size_t) n, f) != (size_t) n) {
        free(p);
        p = NULL;
    }
    fclose(f);
    *len = (size_t) n;
    return p;
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void) argc;
    (void) argv;
    if (atexit(report_judged) != 0) abort();
    const char *path = getenv("DS_FUZZ_CACHE_DSC");
    if (path == NULL || (program = read_file(path, &program_len)) == NULL) {
        fprintf(stderr, "fuzz_cache_roundtrip: DS_FUZZ_CACHE_DSC names no "
                        "readable program\n");
        abort();
    }
    return 0;
}

/* What the set callback saw for "out". */
typedef struct {
    unsigned calls;
    char    *text;      /* the String's bytes, copied */
    size_t   len;
} seen_t;

static ds_result_t on_set(ds_engine_t *engine, const ds_cache_write_t *write, void *user)
{
    (void) engine;
    const ds_json_t *value = write->value;
    seen_t *s = user;
    if (strcmp(write->key, "out") != 0) FAIL("a rule wrote a key the program does not write");
    s->calls++;
    ds_json_kind_t k;
    const char    *str = NULL;
    size_t         len = 0;
    if (ds_json_get_kind(value, &k).status != DS_OK || k != DS_JSON_STRING
        || ds_json_get_string(value, &str, &len).status != DS_OK || str == NULL)
        FAIL("\"out\" was written with something other than a String");
    if (str[len] != '\0') FAIL("the String written under \"out\" is not NUL at its length");
    free(s->text);
    s->text = malloc(len + 1u);
    if (s->text == NULL) abort();
    memcpy(s->text, str, len + 1u);
    s->len = len;
    return DS_OK_R;
}

static void run(const char *key, const ds_json_t *tree)
{
    ds_engine_config_t cfg;
    ds_engine_t       *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return;
    ds_result_t r = ds_engine_load_dsc(e, program, program_len);
    if (r.status != DS_OK) {
        fprintf(stderr, "fuzz_cache_roundtrip: the program does not load: %d %s\n",
                (int) r.status, r.detail != NULL ? r.detail : "");
        abort();
    }
    seen_t seen = { 0, NULL, 0 };
    if (ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, on_set, NULL,
                                  &seen).status != DS_OK)
        FAIL("ds_engine_cache_callbacks refused a callback of this header's ABI");

    /* 1. The seed. */
    r = ds_engine_cache_seed(e, key, tree, DS_CACHE_TTL_NONE);
    if (r.status == DS_ERR_CONTRACT_BREACH) goto done;
    if (r.status != DS_OK) FAIL("ds_engine_cache_seed answered a status libds.h does not document");
    seeded++;

    /* 3. The pump. */
    const ds_schema_t *probe = NULL;
    if (ds_engine_schema_find(e, "Probe", &probe).status != DS_OK || probe == NULL)
        FAIL("the program declares no Probe");
    ds_slot_value_t slot;
    memset(&slot, 0, sizeof slot);
    slot.kind = DS_SLOT_STRING;
    slot.v.s = key;
    if (ds_engine_assert(e, probe, &slot, 1u, NULL).status != DS_OK)
        FAIL("ds_engine_assert refused a Probe");
    if (ds_engine_pump(e).status != DS_OK) FAIL("ds_engine_pump did not answer DS_OK");

    /* 2. The value came back. */
    char  *text = NULL;
    size_t len = 0;
    if (ds_json_serialize(tree, &text, &len).status != DS_OK || text == NULL) abort();
    if (len > DS_JSON_MAX_STRING_BYTES) {
        if (seen.calls != 0)
            FAIL("a String over DS_JSON_MAX_STRING_BYTES was written to the cache");
        over_limit++;
    } else {
        if (seen.calls != 1) FAIL("\"out\" was not written exactly once");
        if (seen.len != len || memcmp(seen.text, text, len) != 0)
            FAIL("cached() did not hand back the canonical text of the seeded value");
        came_back++;
    }
    ds_free(text);
done:
    free(seen.text);
    ds_engine_free(e);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0) return 0;
    size_t klen = data[0] % (MAX_KEY + 1u);
    if (1u + klen > size) return 0;
    static const char fold[] = "abcdefghijklmnopqrstuvwxyz0123456789_";
    char key[MAX_KEY + 1u];
    for (size_t i = 0; i < klen; i++) key[i] = fold[data[1 + i] % (sizeof fold - 1u)];
    key[klen] = '\0';

    ds_json_t *tree = NULL;
    const char *text = (const char *) data + 1 + klen;
    if (ds_json_parse(text, size - 1u - klen, &tree).status != DS_OK) return 0;
    judged++;
    run(key, tree);
    ds_json_free(tree);
    return 0;
}

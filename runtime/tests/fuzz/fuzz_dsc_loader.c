/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_dsc_loader.c -- coverage-guided fuzzing of ds_engine_load_dsc, one of
 * libds's two untrusted buffers ([IARC.1.14]); the other, a recorded fact
 * stream, is fuzz_rfcs_reader.c's and fuzz_rfcs_replay.c's. The gate runs it
 * under ASan and UBSan, for memory safety on adversarial bytes: truncated
 * varints, overflowing lengths, frames nested to exhaustion, field numbers
 * no atom has.
 *
 * WHAT IT ASSERTS, beyond "did not crash":
 *
 *   1. A load that fails leaves an engine that can still be freed. ASan and
 *      LSan judge this.
 *   2. Loading the same bytes into two fresh engines gives the same verdict:
 *      the loader is a pure function of its input ([LDET]).
 *
 * EVERY INPUT IS SEALED BEFORE IT IS LOADED. The loader refuses a
 * `dsc_sha256` mismatch ([RDSC.3.6]) before its second atom, and almost no
 * mutation keeps a valid seal, so each input is sealed as the compiler would
 * seal it and the parser behind the check is what gets searched. The raw
 * bytes are loaded too, on the sampled executions, so the refusal stays
 * covered.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "sha256.h"
#include "pbf_reader.h"
#include "atom_registry.h"

/* DS_FUZZ_VERDICT set: print each load's status and detail on stderr, as
   `DS_FUZZ_VERDICT <status> <detail>`, so the gate sees where a pinned
   reproducer stopped. */
static int verdict_wanted(void)
{
    static int wanted = -1;
    if (wanted < 0) wanted = getenv("DS_FUZZ_VERDICT") != NULL;
    return wanted;
}

/* One load into a fresh engine, freed whatever the outcome. Returns the
   status. */
static int load_once(const uint8_t *data, size_t len)
{
    ds_engine_config_t cfg;
    ds_engine_t       *engine = NULL;
    ds_result_t        r;

    memset(&cfg, 0, sizeof cfg);          /* 0 == engine defaults throughout */

    if (ds_engine_new(&cfg, &engine).status != 0 || engine == NULL) {
        return -1;                        /* OOM under the fuzzer: not a finding */
    }

    r = ds_engine_load_dsc(engine, data, len);
    /* Before the free: `detail` is valid only until the next call on this
       engine. */
    if (verdict_wanted()) {
        fprintf(stderr, "DS_FUZZ_VERDICT %d %s\n", (int) r.status,
                r.detail != NULL ? r.detail : "");
    }

    ds_engine_free(engine);
    return (int) r.status;
}

/* How often the idempotence check runs. Sampled because a second engine
   build halves throughput, and a non-deterministic loader is
   non-deterministic on every execution of the offending input, which SEARCH
   re-runs. REPLAY runs each input once, so `_fuzz_replay` sets
   DS_FUZZ_IDEMPOTENCE_EVERY=1. Unset, empty or not a positive number means
   64. */
#define IDEMPOTENCE_EVERY_DEFAULT 64ul

static unsigned long idempotence_every(void)
{
    static unsigned long every;
    if (every == 0ul) {
        const char   *s = getenv("DS_FUZZ_IDEMPOTENCE_EVERY");
        char         *end = NULL;
        unsigned long n = (s != NULL && *s != '\0') ? strtoul(s, &end, 10) : 0ul;
        every = (n > 0ul && end != NULL && *end == '\0')
              ? n : IDEMPOTENCE_EVERY_DEFAULT;
    }
    return every;
}

/* Seal `buf` in place, as the compiler does ([RDSC.3.6]): when the first atom
   is a DscHeader carrying a 32-byte field 7, zero it, hash the whole buffer
   and write the digest in. Anything else is left as it is. */
static void seal_in_place(uint8_t *buf, size_t len)
{
    ds_pbf_atom_t a;
    if (ds_pbf_next_atom(buf, len, 0, &a) != DS_PBF_OK) return;
    if (a.field != DS_ATOM_DSC_HEADER) return;
    size_t pos = 0;
    while (pos < a.body_len) {
        ds_pbf_field_t f;
        if (ds_pbf_next_field(a.body, a.body_len, pos, &f) != DS_PBF_OK) return;
        if (f.field == 7u && f.wire == 2u && f.val_len == 32u) {
            uint8_t *field = buf + (f.val - buf);
            uint8_t  digest[32];
            memset(field, 0, 32);
            ds_sha256(buf, len, digest);
            memcpy(field, digest, 32);
            return;
        }
        pos = f.next;
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    static unsigned long counter;   /* per process, so per child in fork mode */

    /* The input is libFuzzer's and read-only; the seal goes on a copy. */
    uint8_t *sealed = malloc(size ? size : 1u);
    if (sealed == NULL) return 0;         /* OOM under the fuzzer: not a finding */
    if (size) memcpy(sealed, data, size);
    seal_in_place(sealed, size);

    int first = load_once(sealed, size);

    /* Assertion 2. */
    if ((counter++ % idempotence_every()) == 0ul) {
        int second = load_once(sealed, size);
        if (first != second) {
            __builtin_trap();
        }
        /* The raw bytes, so the [RDSC.3.6] refusal is reached too. */
        (void) load_once(data, size);
    }

    free(sealed);
    return 0;   /* libFuzzer requires 0; findings surface as signals/sanitizers */
}

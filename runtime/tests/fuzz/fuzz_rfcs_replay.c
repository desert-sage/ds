/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_rfcs_replay.c -- coverage-guided fuzzing of libds's replayer: a fact
 * stream applied to an engine, which fuzz_rfcs_reader.c cannot reach.
 * [RDSC.9.9] holds the replayer to the loader's standard: whatever the bytes,
 * it never reads or writes outside what it allocated.
 *
 * WHAT IT DRIVES, by name ([STYL.5.10.8]): ds_rfcs_replay over the whole
 * input, and ds_rfcs_replay_begin / _feed / _finish over the same input cut
 * into two chunks, each into a fresh engine holding the program the gate
 * names in DS_FUZZ_RFCS_DSC. Through them: the header check against the
 * engine's session header and dialect binding, the typed fact-body decoder
 * (ds_rfcs_decode_fact_body and its resolving and announced forms) on every
 * FactAssert and ExternalAssert it applies, the asserts, retracts and clock
 * samples those make, and the byte comparison of every re-derived atom.
 *
 * The program is fixed; fuzz_dsc_loader.c fuzzes programs. The seeds are
 * sessions rfcs_seed_gen recorded against this program, so a mutation starts
 * from a stream that replays cleanly.
 *
 * WHAT IT ASSERTS, beyond "did not crash" (ASan and UBSan judge memory, and
 * every engine is freed, so the reject paths' leaks are LSan's):
 *
 *   1. A REPLAY IS A FUNCTION OF ITS BYTES. The same input replayed into two
 *      fresh engines gives the same status and the same counters. A second
 *      answer that differs means state survived where none may ([LFST.9.6]:
 *      replay is the deterministic re-run).
 *   2. THE CHUNKED FORM IS THE WHOLE FORM. ds_rfcs_replay runs through
 *      begin / feed / finish, so feeding the bytes in two chunks must apply
 *      the same atoms, and reach the same status, as feeding them whole --
 *      except that a short tail is END for the chunked reader and a refusal
 *      for the whole-buffer one ([RFCS.19.2]). So the comparison is made
 *      when the chunked replay reports no tail.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"

static uint8_t *program;
static size_t   program_len;

/* How often the second whole replay and the chunked one run: on one input in
   `check_every`. Each builds an engine and loads the program, which costs far
   more than reading the bytes, so SEARCH samples them. REPLAY passes 1 in
   DS_FUZZ_RFCS_CHECK_EVERY, so every seed is checked on every run. */
static unsigned long check_every = 16u;

/* The inputs both properties ran on, printed at exit. The gate reads it after
   REPLAY and refuses a count below the seeds', so a sampling that checks
   nothing fails the lane instead of passing it. */
static unsigned long checked;

static void report_checked(void)
{
    fprintf(stderr, "fuzz_rfcs_replay: properties checked on %lu input(s)\n",
            checked);
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

/* The program, read once. A missing or unloadable program, or a sampling
   rate that is not a positive integer, stops the run: either would make
   every input a silent pass. */
int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void) argc;
    (void) argv;
    const char *every = getenv("DS_FUZZ_RFCS_CHECK_EVERY");
    if (every != NULL) {
        char *end = NULL;
        check_every = strtoul(every, &end, 10);
        if (end == every || *end != '\0' || check_every == 0u) {
            fprintf(stderr, "fuzz_rfcs_replay: DS_FUZZ_RFCS_CHECK_EVERY=%s is "
                            "not a positive integer\n", every);
            abort();
        }
    }
    fprintf(stderr, "fuzz_rfcs_replay: properties sampled on 1 input in %lu\n",
            check_every);
    if (atexit(report_checked) != 0) abort();
    const char *path = getenv("DS_FUZZ_RFCS_DSC");
    if (path == NULL || (program = read_file(path, &program_len)) == NULL) {
        fprintf(stderr, "fuzz_rfcs_replay: DS_FUZZ_RFCS_DSC names no readable "
                        "program\n");
        abort();
    }
    ds_engine_config_t cfg;
    ds_engine_t       *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) abort();
    ds_result_t r = ds_engine_load_dsc(e, program, program_len);
    if (r.status != DS_OK) {
        fprintf(stderr, "fuzz_rfcs_replay: the program does not load: %d %s\n",
                (int) r.status, r.detail != NULL ? r.detail : "");
        abort();
    }
    ds_engine_free(e);
    return 0;
}

typedef struct {
    int                     status;
    ds_rfcs_replay_result_t res;
} outcome_t;

/* A fresh engine holding the program, on the mock clock. The replayer moves
   to the mock clock only at the stream's first ClockAdvance, and a mutated
   stream may assert before one; on the live clock, two replays of it could
   differ by the time alone. */
static ds_engine_t *fresh(void)
{
    ds_engine_config_t cfg;
    ds_engine_t       *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return NULL;
    if (ds_engine_load_dsc(e, program, program_len).status != DS_OK
        || ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

/* The whole-buffer replay. Returns false when no engine could be built (OOM
   under the fuzzer: not a finding). */
static bool replay_whole(const uint8_t *data, size_t size, outcome_t *o)
{
    ds_engine_t *e = fresh();
    if (e == NULL) return false;
    /* [rfcs.h]: at least 2 * len covers every string and its terminator. */
    size_t   cap = 2u * size + 16u;
    uint8_t *strbuf = malloc(cap);
    if (strbuf == NULL) {
        ds_engine_free(e);
        return false;
    }
    memset(&o->res, 0, sizeof o->res);
    o->status = (int) ds_rfcs_replay(e, data, size, strbuf, cap,
                                     &o->res).status;
    ds_engine_free(e);
    free(strbuf);
    return true;
}

/* The chunked replay, the input cut at `cut`. */
static bool replay_chunked(const uint8_t *data, size_t size, size_t cut,
                           outcome_t *o)
{
    ds_engine_t *e = fresh();
    if (e == NULL) return false;
    ds_rfcs_replay_ctx_t *ctx = NULL;
    memset(&o->res, 0, sizeof o->res);
    ds_result_t r = ds_rfcs_replay_begin(e, NULL, &ctx);
    if (r.status == DS_OK) {
        r = ds_rfcs_replay_feed(ctx, data, cut);
        ds_result_t r2 = ds_rfcs_replay_feed(ctx, data + cut, size - cut);
        if (r.status == DS_OK) r = r2;
        ds_result_t r3 = ds_rfcs_replay_finish(ctx, &o->res);
        if (r.status == DS_OK) r = r3;
    }
    o->status = (int) r.status;
    ds_engine_free(e);
    return true;
}

static bool same(const outcome_t *a, const outcome_t *b)
{
    return a->status == b->status
        && a->res.asserts == b->res.asserts
        && a->res.retracts == b->res.retracts
        && a->res.clocks == b->res.clocks
        && a->res.rule_fires == b->res.rule_fires
        && a->res.calls == b->res.calls
        && a->res.withdrawals == b->res.withdrawals
        && a->res.skipped == b->res.skipped
        && a->res.header_verified == b->res.header_verified;
}

/* FNV-1a over the input. The sample is chosen by the input, not a call
   counter, so a given input is always checked or never, whatever ran before
   it in the process. */
static uint64_t input_hash(const uint8_t *data, size_t size)
{
    uint64_t h = 0xcbf29ce484222325u;
    for (size_t i = 0; i < size; i++) {
        h ^= data[i];
        h *= 0x100000001b3u;
    }
    return h;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    outcome_t first;
    if (!replay_whole(data, size, &first)) return 0;

    if (input_hash(data, size) % check_every != 0u) return 0;
    checked++;

    /* 1. A replay is a function of its bytes. */
    outcome_t second;
    if (replay_whole(data, size, &second) && !same(&first, &second)) {
        __builtin_trap();
    }

    /* 2. The chunked form is the whole form, where it reports no tail. */
    size_t    cut = size ? (size_t) data[size - 1] % (size + 1u) : 0u;
    outcome_t chunked;
    if (replay_chunked(data, size, cut, &chunked) && chunked.res.tail_bytes == 0
        && !same(&first, &chunked)) {
        __builtin_trap();
    }
    return 0;
}

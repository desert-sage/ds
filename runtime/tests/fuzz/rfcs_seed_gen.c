/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * rfcs_seed_gen.c -- the fact-stream fuzz targets' seeds: real recordings,
 * written by THIS libds.
 *
 *     rfcs_seed_gen <out-dir> <program.dsc>
 *
 * The seeds are sessions recorded against the program the replay target
 * loads, by the libds archive the targets link, so a seed replays cleanly
 * before it is mutated. None is committed: a committed recording carries the
 * DS version that wrote it, and is refused at the header once the version
 * moves ([LDET.1.10]).
 *
 * Each session asserts one fact of every schema the program registers, with
 * every slot set from one value V, pumping after each; the first is retracted
 * and asserted again before its pump, so the session holds a retract. Then it
 * advances the mock clock past every ttl and pumps. V is 0, 1 and 2, so a rule
 * whose guard needs a non-zero value fires in one session and not in another,
 * and an Int division by V traps in one. Asserts the engine refuses are
 * skipped: a schema the program reads but the host may not assert is part of
 * every program, and the session goes on without it. Every refusal is
 * written to stdout, so the gate's log says what a seed holds.
 *
 * Exit 0 with at least one recording written; 1 otherwise, so a seed set that
 * silently came out empty fails the gate rather than fuzzing nothing.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"

#define MAX_SLOTS 64u

typedef struct {
    uint8_t *p;
    size_t   len;
    size_t   cap;
} buf_t;

static ds_result_t sink(const uint8_t *bytes, size_t len, void *user)
{
    buf_t *b = user;
    if (b->len + len > b->cap) {
        size_t cap = b->cap ? b->cap * 2u : 4096u;
        while (cap < b->len + len) cap *= 2u;
        uint8_t *p = realloc(b->p, cap);
        if (p == NULL) {
            ds_result_t r = { .status = DS_ERR_OOM, .detail = "seed sink" };
            return r;
        }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->len, bytes, len);
    b->len += len;
    ds_result_t ok = { .status = DS_OK, .detail = NULL };
    return ok;
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

/* One value per slot, from V. A fact-reference slot is null where the slot
   is nullable; otherwise the schema is skipped (`false`), since this session
   holds no fact of the right schema to point at. */
static bool fill(const ds_schema_t *schema, int64_t v, ds_slot_value_t *vals,
                 uint32_t *n_out, ds_json_t **json_out)
{
    static const uint8_t bytes[] = { 0x00, 0x01, 0xff };
    uint32_t n = 0;
    *json_out = NULL;
    if (ds_schema_get_slot_count(schema, &n).status != DS_OK || n > MAX_SLOTS)
        return false;
    for (uint32_t i = 0; i < n; i++) {
        ds_slot_desc_t d;
        if (ds_schema_get_slot(schema, i, &d).status != DS_OK) return false;
        memset(&vals[i], 0, sizeof vals[i]);
        switch (d.type) {
        case DS_SLOT_TYPE_INT:
        case DS_SLOT_TYPE_TIME:
        case DS_SLOT_TYPE_DATE:
        case DS_SLOT_TYPE_DURATION:
            vals[i].kind = DS_SLOT_INT;
            vals[i].v.i = v;
            break;
        case DS_SLOT_TYPE_FLOAT:
            vals[i].kind = DS_SLOT_FLOAT;
            vals[i].v.f = (double) v + 0.5;
            break;
        case DS_SLOT_TYPE_STRING:
            vals[i].kind = DS_SLOT_STRING;
            vals[i].v.s = v == 0 ? "low" : v == 1 ? "a" : "b";
            break;
        case DS_SLOT_TYPE_BOOL:
            vals[i].kind = DS_SLOT_BOOL;
            vals[i].v.b = v != 0;
            break;
        case DS_SLOT_TYPE_BYTES:
            vals[i].kind = DS_SLOT_BYTES;
            vals[i].v.bytes.data = bytes;
            vals[i].v.bytes.len = (size_t) v % sizeof bytes + 1u;
            break;
        case DS_SLOT_TYPE_JSON: {
            static const char doc[] = "{\"a\":[1,2.5,\"x\",null,true]}";
            if (*json_out == NULL
                && ds_json_parse(doc, sizeof doc - 1u, json_out).status != DS_OK)
                return false;
            vals[i].kind = DS_SLOT_JSON;
            vals[i].v.json = *json_out;
            break;
        }
        case DS_SLOT_TYPE_SCHEMA:
            if (!d.nullable) return false;
            vals[i].kind = DS_SLOT_NULL;
            break;
        default:
            return false;
        }
    }
    *n_out = n;
    return true;
}

static void say(const char *what, ds_result_t r)
{
    if (r.status != DS_OK)
        printf("    %s: %d %s\n", what, (int) r.status,
               r.detail != NULL ? r.detail : "");
}

/* One recorded session at V. Returns its bytes in *out (caller frees). */
static int session(const uint8_t *dsc, size_t dsc_len, int64_t v, buf_t *out)
{
    ds_engine_config_t cfg;
    ds_engine_t       *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    memset(out, 0, sizeof *out);
    if (ds_engine_new(&cfg, &e).status != DS_OK || e == NULL) return -1;

    ds_result_t r = ds_engine_load_dsc(e, dsc, dsc_len);
    if (r.status != DS_OK) {
        say("load", r);
        ds_engine_free(e);
        return -1;
    }
    say("mock clock", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));

    static uint8_t scratch[1u << 16];
    ds_rfcs_recorder_t rec;
    r = ds_rfcs_record_to(e, &rec, sink, out, scratch, sizeof scratch);
    if (r.status != DS_OK) {
        say("record_to", r);
        ds_engine_free(e);
        return -1;
    }

    size_t      count = 0;
    bool        retracted = false;
    (void) ds_engine_schema_count(e, &count);
    for (size_t s = 0; s < count; s++) {
        const ds_schema_t *schema = NULL;
        const char        *name = "?";
        if (ds_engine_schema_at(e, s, &schema).status != DS_OK) continue;
        (void) ds_schema_get_name(schema, &name);

        ds_slot_value_t vals[MAX_SLOTS];
        uint32_t        n = 0;
        ds_json_t      *json = NULL;
        if (!fill(schema, v, vals, &n, &json)) {
            printf("    %s: skipped (a slot this session cannot fill)\n", name);
            ds_json_free(json);
            continue;
        }
        ds_fact_t *fact = NULL;
        r = ds_engine_assert(e, schema, vals, n, &fact);
        if (r.status != DS_OK) {
            say(name, r);
            ds_json_free(json);
            continue;
        }
        /* One retract per session, of the first fact, before any pump: a
           fact handle is valid only while the fact is live, and a pump may
           end it. */
        if (!retracted) {
            retracted = true;
            say("retract", ds_engine_retract(e, fact));
            say(name, ds_engine_assert(e, schema, vals, n, &fact));
        }
        ds_json_free(json);
        say("pump", ds_engine_pump(e));
    }
    say("advance", ds_engine_clock_advance(e, 120ull * 1000000000ull));
    say("pump", ds_engine_pump(e));

    (void) ds_engine_set_stream_callback(e, NULL, NULL);
    say("recorder", rec.last);
    ds_engine_free(e);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: rfcs_seed_gen <out-dir> <program.dsc>\n");
        return 2;
    }
    size_t   dsc_len = 0;
    uint8_t *dsc = read_file(argv[2], &dsc_len);
    if (dsc == NULL) {
        fprintf(stderr, "rfcs_seed_gen: cannot read %s\n", argv[2]);
        return 1;
    }

    int written = 0;
    for (int64_t v = 0; v <= 2; v++) {
        printf("=== session V=%lld ===\n", (long long) v);
        buf_t b;
        if (session(dsc, dsc_len, v, &b) != 0 || b.len == 0) {
            printf("    no recording\n");
            free(b.p);
            continue;
        }
        char path[4096];
        snprintf(path, sizeof path, "%s/session-%lld.rfcs", argv[1],
                 (long long) v);
        FILE *f = fopen(path, "wb");
        if (f == NULL || fwrite(b.p, 1, b.len, f) != b.len) {
            fprintf(stderr, "rfcs_seed_gen: cannot write %s\n", path);
            if (f != NULL) fclose(f);
            free(b.p);
            free(dsc);
            return 1;
        }
        fclose(f);
        printf("    %s: %zu bytes\n", path, b.len);
        written++;
        free(b.p);
    }
    free(dsc);
    if (written == 0) {
        fprintf(stderr, "rfcs_seed_gen: no session recorded anything\n");
        return 1;
    }
    return 0;
}

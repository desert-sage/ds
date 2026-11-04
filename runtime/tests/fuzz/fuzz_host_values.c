/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_host_values.c -- coverage-guided fuzzing of the values a host hands a
 * running engine, through libds.h only. A host asserts facts whose String,
 * Bytes, Int, Float, Bool and Json slots hold whatever it was given, and every
 * operation a rule runs on a slot meets those bytes: the interning, the length
 * reads, interpolation, a regex, the casts, a Json path, the cache, a call's
 * arguments, an emit and a publish. host_values.ds (named by
 * DS_FUZZ_HOST_DSC) routes a Host fact through each family. A When fact carries a
 * Time, a Date and a zone designation, which the program resolves through the
 * TimeZoneOffset rows the script asserts ([LTIM.10.6], [LTIM.10.7]); and the
 * engine's run_id and tier_id, which every event_id is derived from, come from
 * the script too.
 *
 * THE INPUT IS A SCRIPT, one engine per input, on the mock clock with the wall
 * clock set. Each op is a byte, taken modulo the op count, and its operands:
 *
 *   ASSERT  id:u8  s:str  u:str  i:i64  f:f64  ok:u8  b:str  j:str
 *           a Host; `str` is a u16 length (LE) and that many bytes. j is JSON
 *           text: ds_json_parse's tree, or JSON null where it refuses the text
 *           (fuzz_json_text owns that). The f64 is its raw bits, NaN included.
 *   PUMP
 *   ADVANCE delta:u32, in microseconds, on the mock clock
 *   WALL    utc:i64, the mock wall clock
 *   SEED    key:str value:str  a cache seed, the value parsed as j is; legal
 *           only before the engine's first event, after which it is
 *           DS_ERR_STATE
 *   WHEN    id:u8 t:i64 d:i64 z:str
 *           a When: t a Time, d a Date's day count, both raw, and z a zone
 *           designation. A d outside the Date range is DS_ERR_TIME_RANGE
 *           ([LTIM.1.2.2])
 *   ZONE    zone:str from:i64 until:i64 offset:i64
 *           a TimeZoneOffset row, each field raw: a period that is not one,
 *           an offset past eighteen hours or the zone "UTC" is DS_ERR_INVAL
 *           ([LTIM.10.9])
 *   IDS     run:str tier:str
 *           a new engine whose run_id and tier_id they are, set up as the
 *           first was, replaces the one the script has run so far, which is
 *           pumped once more and freed. One ds_engine_new refuses
 *           (DS_ERR_ENCODING, [NLFC.1.2]) leaves the current one in place
 *
 * A script that runs out of bytes mid-op stops there; the engine is pumped
 * once more and freed. Retract is no op: it carries no host value, only a
 * fact's handle, and a superseded fact's handle is invalidated by the engine,
 * so a script that retracted by handle could make the harness, not libds,
 * read freed memory. Assert and retract churn is the `fuzz` gate's
 * (specs/conformance/harness/rete_churn_fuzz.py), which tracks each live
 * handle.
 *
 * WHAT IT ASSERTS, each a trap (ASan judges memory, every engine and tree is
 * freed, and REPLAY runs with leaks on):
 *
 *   1. EVERY STATUS IS DOCUMENTED. Each call answers DS_OK or a status
 *      libds.h names for that call: ds_engine_assert's list (DS_ERR_INVAL,
 *      _SLOT_TYPE_MISMATCH, _ENCODING, _TIME_RANGE), DS_ERR_NAN_REJECTED, which
 *      the header defines as an assert's refusal, and DS_ERR_CONTRACT_BREACH,
 *      a cap; ds_engine_cache_seed's (DS_ERR_STATE after the first event, and
 *      DS_ERR_ENCODING, _CONTRACT_BREACH, _TIME_RANGE, _JSON_NONFINITE);
 *      ds_engine_new's (DS_ERR_ENCODING), which also leaves no engine.
 *   2. NO HOST VALUE HALTS THE ENGINE. An EngineError is the engine's own
 *      defect ([LERR.1.4.7]); what a rule does to a host value faults with a
 *      ComputationError or a TypeError, which host_values.ds logs. So a pump
 *      answering DS_ERR_ENGINE_HALTED is a finding.
 *   3. WHAT LEAVES THE ENGINE IS WELL-FORMED UTF-8. Every host string entered
 *      as well-formed UTF-8 ([LSTR.8.5]), so every log message, every String
 *      call argument and every string in a cache value or a Json call argument
 *      is well-formed too, and its strlen is its length: a cut through a code
 *      point, or a NUL inside, is a defect in whatever built it.
 *   4. A CALL IS THE ONE DECLARED. Its service is `sink.take`, its arguments
 *      are sorted by name, and each has the kind its kwarg declares.
 *
 * The counts are printed at exit and read by the gate, which refuses a REPLAY
 * in which an assert, a pump, a log, a call, a cache write, a When, a zone row
 * or an engine with ids never happened.
 */

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#define FAIL(why) do {                                          \
        fprintf(stderr, "fuzz_host_values: %s\n", (why));       \
        __builtin_trap();                                       \
    } while (0)

enum { OP_ASSERT, OP_PUMP, OP_ADVANCE, OP_WALL, OP_SEED, OP_WHEN, OP_ZONE, OP_IDS, OP_COUNT };

/* The Host schema's slots, in declaration order. */
enum { H_ID, H_S, H_U, H_I, H_F, H_OK, H_B, H_J, H_SLOTS };

/* When's, and TimeZoneOffset's ([LTIM.10.6]), each checked by name at setup. */
enum { W_ID, W_T, W_D, W_Z, W_SLOTS };
enum { Z_ZONE, Z_FROM, Z_UNTIL, Z_OFFSET, Z_SLOTS };
static const char *const when_slots[W_SLOTS] = { "id", "t", "d", "z" };
static const char *const zone_slots[Z_SLOTS] = {
    "zone", "valid_from", "valid_until", "offset_s" };

static uint8_t *program;
static size_t   program_len;

static unsigned long judged, asserted, pumped, logged, called, cached;
static unsigned long timed, zoned, named;

static void report_judged(void)
{
    fprintf(stderr, "fuzz_host_values: judged %lu input(s): %lu asserted, "
                    "%lu pumped, %lu logged, %lu called, %lu cached, "
                    "%lu timed, %lu zoned, %lu named\n",
            judged, asserted, pumped, logged, called, cached, timed, zoned,
            named);
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
    const char *path = getenv("DS_FUZZ_HOST_DSC");
    if (path == NULL || (program = read_file(path, &program_len)) == NULL) {
        fprintf(stderr, "fuzz_host_values: DS_FUZZ_HOST_DSC names no readable "
                        "program\n");
        abort();
    }
    return 0;
}

/* RFC 3629: no overlong, no surrogate, nothing above U+10FFFF, no NUL. */
static bool well_formed(const uint8_t *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        size_t  k;
        uint32_t cp;
        if (c == 0) return false;
        if (c < 0x80) { i++; continue; }
        if (c >= 0xc2 && c <= 0xdf)      { k = 1; cp = c & 0x1f; }
        else if (c >= 0xe0 && c <= 0xef) { k = 2; cp = c & 0x0f; }
        else if (c >= 0xf0 && c <= 0xf4) { k = 3; cp = c & 0x07; }
        else return false;
        if (n - i <= k) return false;           /* the sequence runs past n */
        for (size_t j = 1; j <= k; j++) {
            if ((s[i + j] & 0xc0) != 0x80) return false;
            cp = (cp << 6) | (s[i + j] & 0x3f);
        }
        if ((k == 2 && cp < 0x800) || (k == 3 && cp < 0x10000)
            || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff)
            return false;
        i += k + 1;
    }
    return true;
}

static void check_text(const char *s, size_t n, const char *what)
{
    if (s == NULL) FAIL(what);
    if (s[n] != '\0' || strlen(s) != n) FAIL(what);
    if (!well_formed((const uint8_t *) s, n)) FAIL(what);
}

static void check_tree(const ds_json_t *n)
{
    ds_json_kind_t k;
    if (ds_json_get_kind(n, &k).status != DS_OK) FAIL("a Json value leaving the engine has no kind");
    size_t len = 0;
    if (k == DS_JSON_STRING) {
        const char *s;
        ds_json_get_string(n, &s, &len);
        check_text(s, len, "a Json string leaving the engine is not well-formed UTF-8");
    } else if (k == DS_JSON_ARRAY) {
        ds_json_array_len(n, &len);
        for (size_t i = 0; i < len; i++) {
            const ds_json_t *c;
            ds_json_array_at(n, i, &c);
            check_tree(c);
        }
    } else if (k == DS_JSON_OBJECT) {
        ds_json_object_len(n, &len);
        for (size_t i = 0; i < len; i++) {
            const char      *key;
            size_t           klen;
            const ds_json_t *c;
            ds_json_object_at(n, i, &key, &klen, &c);
            check_text(key, klen, "a Json key leaving the engine is not well-formed UTF-8");
            check_tree(c);
        }
    }
}

static ds_result_t on_log(ds_engine_t *engine, const ds_log_event_t *ev, void *user)
{
    (void) engine;
    (void) user;
    logged++;
    if (ev == NULL || ev->message == NULL) FAIL("a log event carries no message");
    check_text(ev->message, strlen(ev->message), "a log message is not well-formed UTF-8");
    return DS_OK_R;
}

/* sink.take's kwargs, sorted by name, and the kind each declares. */
static const struct { const char *name; ds_arg_kind_t kind; } kwargs[] = {
    { "b", DS_ARG_BYTES }, { "f", DS_ARG_FLOAT }, { "i", DS_ARG_INT },
    { "j", DS_ARG_JSON },  { "s", DS_ARG_STRING },
};

static ds_result_t on_call(ds_engine_t *engine, const ds_call_request_t *rq, void *user)
{
    (void) engine;
    (void) user;
    called++;
    if (rq == NULL || rq->service == NULL || strcmp(rq->service, "sink.take") != 0)
        FAIL("a call names a service the program does not call");
    if (rq->correlation == NULL || rq->correlation[0] == '\0')
        FAIL("a call has no correlation");
    if (rq->arg_count != sizeof kwargs / sizeof kwargs[0])
        FAIL("a call does not carry the kwargs the rule supplies");
    for (uint32_t a = 0; a < rq->arg_count; a++) {
        const ds_arg_t *arg = &rq->args[a];
        if (arg->name == NULL || strcmp(arg->name, kwargs[a].name) != 0)
            FAIL("a call's arguments are not its kwargs, sorted by name");
        if (arg->value.kind != kwargs[a].kind)
            FAIL("a call argument is not the kind its kwarg declares");
        if (arg->value.kind == DS_ARG_STRING)
            check_text(arg->value.v.s, strlen(arg->value.v.s),
                       "a String call argument is not well-formed UTF-8");
        if (arg->value.kind == DS_ARG_JSON) {
            if (arg->value.v.json == NULL) FAIL("a Json call argument is no tree");
            check_tree(arg->value.v.json);
        }
        if (arg->value.kind == DS_ARG_FLOAT && isnan(arg->value.v.f))
            FAIL("a NaN reached a call argument");
    }
    return DS_OK_R;
}

static ds_result_t on_cache_set(ds_engine_t *engine, const ds_cache_write_t *write, void *user)
{
    (void) engine;
    (void) user;
    cached++;
    if (write->key == NULL || (strcmp(write->key, "s") != 0 && strcmp(write->key, "j") != 0))
        FAIL("a rule wrote a cache key the program does not write");
    if (write->value == NULL) FAIL("a cache write carries no value");
    check_tree(write->value);
    return DS_OK_R;
}

/* The EngineError a halt carried, kept for the trap's message: its rule and
   node name the operation, which the halt latch alone does not. */
static char     halt_rule[128];
static uint32_t halt_node;

/* The wall clock the script has left the current engine at, which every TICK
   must carry: a refused advance moves nothing ([NTST.3.1]). */
#define WALL_AT_SETUP INT64_C(1700000000000000000)
static int64_t wall_now;

static ds_result_t on_stream(ds_engine_t *engine, const ds_stream_ev_t *ev, void *user)
{
    (void) engine;
    (void) user;
    if (ev != NULL && ev->kind == DS_EV_TICK
        && (!ev->p.tick.wall_set || ev->p.tick.wall_ns != wall_now))
        FAIL("a TICK carries a wall clock the script did not leave");
    if (ev != NULL && ev->kind == DS_EV_ENGINE_ERROR) {
        const char *r = ev->p.engine_error.rule_name;
        snprintf(halt_rule, sizeof halt_rule, "%s", r != NULL ? r : "(null)");
        halt_node = ev->p.engine_error.node_id;
    }
    return DS_OK_R;
}

/* ---- the script reader ---- */

typedef struct {
    const uint8_t *p;
    size_t         left;
} cursor_t;

static bool take(cursor_t *c, void *out, size_t n)
{
    if (c->left < n) return false;
    memcpy(out, c->p, n);
    c->p += n;
    c->left -= n;
    return true;
}

/* A `str` operand, copied NUL-terminated (a C string slot needs the NUL; the
   copy is the host's own buffer, which the engine copies at assert). */
static char *take_str(cursor_t *c, size_t *len)
{
    uint8_t lb[2];
    if (!take(c, lb, 2)) return NULL;
    size_t n = (size_t) lb[0] | ((size_t) lb[1] << 8);
    if (c->left < n) return NULL;
    char *s = malloc(n + 1u);
    if (s == NULL) abort();
    memcpy(s, c->p, n);
    s[n] = '\0';
    c->p += n;
    c->left -= n;
    *len = n;
    return s;
}

static ds_json_t *tree_of(const char *text, size_t len)
{
    ds_json_t *t = NULL;
    if (ds_json_parse(text, len, &t).status == DS_OK) return t;
    if (ds_json_new_null(&t).status != DS_OK) abort();
    return t;
}

static bool assert_documented(int st)
{
    return st == DS_OK || st == DS_ERR_INVAL || st == DS_ERR_SLOT_TYPE_MISMATCH
        || st == DS_ERR_ENCODING || st == DS_ERR_TIME_RANGE
        || st == DS_ERR_NAN_REJECTED || st == DS_ERR_CONTRACT_BREACH;
}

static bool seed_documented(int st)
{
    return st == DS_OK || st == DS_ERR_STATE || st == DS_ERR_ENCODING
        || st == DS_ERR_CONTRACT_BREACH || st == DS_ERR_TIME_RANGE
        || st == DS_ERR_JSON_NONFINITE;
}

static void pump(ds_engine_t *e)
{
    ds_result_t r = ds_engine_pump(e);
    int st = r.status;
    pumped++;
    if (st == DS_ERR_ENGINE_HALTED) {
        /* Say why before trapping: the fault the halt latch holds, and the
           pump's own detail, so the finding names its cause. */
        bool              halted = false;
        ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
        (void) ds_engine_halted(e, &halted, &fault);
        fprintf(stderr, "fuzz_host_values: halted=%d fault=%d rule=%s node=%u "
                        "detail=%s\n",
                (int) halted, (int) fault, halt_rule, (unsigned) halt_node,
                r.detail != NULL ? r.detail : "");
        FAIL("a host value halted the engine");
    }
    if (st != DS_OK && st != DS_ERR_CONTRACT_BREACH)
        FAIL("ds_engine_pump answered a status libds.h does not document");
}

/* One engine and the three schemas the script asserts. */
typedef struct {
    ds_engine_t       *e;
    const ds_schema_t *host, *when, *zone;
} rig_t;

static const ds_schema_t *find_schema(ds_engine_t *e, const char *name,
                                      const char *const *slots, uint32_t n)
{
    const ds_schema_t *s = NULL;
    uint32_t           count = 0;
    if (ds_engine_schema_find(e, name, &s).status != DS_OK || s == NULL
        || ds_schema_get_slot_count(s, &count).status != DS_OK || count != n)
        FAIL("the program declares no schema the script asserts, or not with "
             "its slots");
    for (uint32_t i = 0; i < n && slots != NULL; i++) {
        ds_slot_desc_t d;
        if (ds_schema_get_slot(s, i, &d).status != DS_OK || d.name == NULL
            || strcmp(d.name, slots[i]) != 0)
            FAIL("a schema the script asserts has its slots in another order");
    }
    return s;
}

/* A new engine with these ids (NULL for none), the program loaded and set up
   as every input's is. NULL, with *st its status, when ds_engine_new refuses
   it, which only DS_ERR_ENCODING may be. */
static ds_engine_t *engine_up(const char *run_id, const char *tier_id, rig_t *rig,
                              int *st)
{
    ds_engine_config_t cfg;
    ds_engine_t       *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    cfg.run_id = run_id;
    cfg.tier_id = tier_id;
    *st = ds_engine_new(&cfg, &e).status;
    if (*st != DS_OK) {
        if (*st != DS_ERR_ENCODING || e != NULL)
            FAIL("ds_engine_new answered a status libds.h does not document");
        return NULL;
    }
    if (e == NULL) FAIL("ds_engine_new answered DS_OK and no engine");
    ds_result_t r = ds_engine_load_dsc(e, program, program_len);
    if (r.status != DS_OK) {
        fprintf(stderr, "fuzz_host_values: the program does not load: %d %s\n",
                (int) r.status, r.detail != NULL ? r.detail : "");
        abort();
    }
    rig->e = e;
    rig->host = find_schema(e, "Host", NULL, H_SLOTS);
    rig->when = find_schema(e, "When", when_slots, W_SLOTS);
    rig->zone = find_schema(e, "TimeZoneOffset", zone_slots, Z_SLOTS);
    if (ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status != DS_OK
        || ds_engine_wall_clock_set(e, WALL_AT_SETUP).status != DS_OK
        || ds_engine_set_log_callback(e, on_log, NULL).status != DS_OK
        || ds_engine_set_stream_callback(e, on_stream, NULL).status != DS_OK
        || ds_engine_set_call_callback(e, on_call, NULL).status != DS_OK
        || ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, on_cache_set,
                                     NULL, NULL).status != DS_OK)
        FAIL("the engine refused its setup");
    return e;
}

static void run(cursor_t *c, rig_t *rig)
{
    for (;;) {
        ds_engine_t *e = rig->e;
        const ds_schema_t *host = rig->host;
        uint8_t op;
        if (!take(c, &op, 1)) return;
        switch (op % OP_COUNT) {
        case OP_ASSERT: {
            uint8_t id, ok;
            int64_t i;
            double  f;
            size_t  sl = 0, ul = 0, bl = 0, jl = 0;
            char *s = NULL, *u = NULL, *b = NULL, *j = NULL;
            bool whole = take(c, &id, 1) && (s = take_str(c, &sl)) != NULL
                && (u = take_str(c, &ul)) != NULL && take(c, &i, 8)
                && take(c, &f, 8) && take(c, &ok, 1)
                && (b = take_str(c, &bl)) != NULL && (j = take_str(c, &jl)) != NULL;
            if (whole) {
                ds_json_t      *tree = tree_of(j, jl);
                ds_slot_value_t v[H_SLOTS];
                memset(v, 0, sizeof v);
                v[H_ID].kind = DS_SLOT_INT;    v[H_ID].v.i = id % 8u;
                v[H_S].kind = DS_SLOT_STRING;  v[H_S].v.s = s;
                v[H_U].kind = DS_SLOT_STRING;  v[H_U].v.s = u;
                v[H_I].kind = DS_SLOT_INT;     v[H_I].v.i = i;
                v[H_F].kind = DS_SLOT_FLOAT;   v[H_F].v.f = f;
                v[H_OK].kind = DS_SLOT_BOOL;   v[H_OK].v.b = ok & 1u;
                v[H_B].kind = DS_SLOT_BYTES;
                v[H_B].v.bytes.data = (const uint8_t *) b;
                v[H_B].v.bytes.len = bl;
                v[H_J].kind = DS_SLOT_JSON;    v[H_J].v.json = tree;
                int st = ds_engine_assert(e, host, v, H_SLOTS, NULL).status;
                if (!assert_documented(st))
                    FAIL("ds_engine_assert answered a status libds.h does not document");
                if (st == DS_OK) asserted++;
                ds_json_free(tree);
            }
            free(s);
            free(u);
            free(b);
            free(j);
            if (!whole) return;
            break;
        }
        case OP_PUMP:
            pump(e);
            break;
        case OP_ADVANCE: {
            uint32_t us;
            if (!take(c, &us, 4)) return;
            /* [NTST.3.1]: past the wall clock's range is refused, with both
               clocks as they were. A 32-bit count of microseconds cannot reach
               the clause's other two bounds. */
            const uint64_t ns = (uint64_t) us * 1000u;
            const bool past = wall_now >= 0
                && ns > (uint64_t) INT64_MAX - (uint64_t) wall_now;
            uint64_t before = 0, after = 0;
            if (ds_engine_clock_now(e, &before).status != DS_OK)
                FAIL("ds_engine_clock_now refused");
            int st = ds_engine_clock_advance(e, ns).status;
            if (ds_engine_clock_now(e, &after).status != DS_OK)
                FAIL("ds_engine_clock_now refused");
            if (past) {
                if (st != DS_ERR_TIME_RANGE)
                    FAIL("an advance past the wall clock's range was not refused");
                if (after != before)
                    FAIL("a refused advance moved the monotonic clock");
            } else {
                if (st != DS_OK)
                    FAIL("ds_engine_clock_advance refused on the mock clock");
                wall_now += (int64_t) ns;
            }
            break;
        }
        case OP_WALL: {
            int64_t utc;
            if (!take(c, &utc, 8)) return;
            if (ds_engine_wall_clock_set(e, utc).status != DS_OK)
                FAIL("ds_engine_wall_clock_set refused on the mock clock");
            wall_now = utc;
            break;
        }
        case OP_SEED: {
            size_t kl = 0, vl = 0;
            char *k = take_str(c, &kl);
            char *val = k != NULL ? take_str(c, &vl) : NULL;
            if (val != NULL) {
                ds_json_t *tree = tree_of(val, vl);
                int st = ds_engine_cache_seed(e, k, tree, DS_CACHE_TTL_NONE).status;
                if (!seed_documented(st))
                    FAIL("ds_engine_cache_seed answered a status libds.h does not document");
                ds_json_free(tree);
            }
            free(k);
            free(val);
            if (val == NULL) return;
            break;
        }
        case OP_WHEN: {
            uint8_t id;
            int64_t t, d;
            size_t  zl = 0;
            char   *z = NULL;
            bool whole = take(c, &id, 1) && take(c, &t, 8) && take(c, &d, 8)
                && (z = take_str(c, &zl)) != NULL;
            if (whole) {
                ds_slot_value_t v[W_SLOTS];
                memset(v, 0, sizeof v);
                v[W_ID].kind = DS_SLOT_INT;    v[W_ID].v.i = id % 8u;
                v[W_T].kind = DS_SLOT_INT;     v[W_T].v.i = t;
                v[W_D].kind = DS_SLOT_INT;     v[W_D].v.i = d;
                v[W_Z].kind = DS_SLOT_STRING;  v[W_Z].v.s = z;
                int st = ds_engine_assert(e, rig->when, v, W_SLOTS, NULL).status;
                if (!assert_documented(st))
                    FAIL("ds_engine_assert answered a status libds.h does not document");
                if (st == DS_OK) timed++;
            }
            free(z);
            if (!whole) return;
            break;
        }
        case OP_ZONE: {
            int64_t from, until, offset;
            size_t  nl = 0;
            char   *name = take_str(c, &nl);
            bool whole = name != NULL && take(c, &from, 8) && take(c, &until, 8)
                && take(c, &offset, 8);
            if (whole) {
                ds_slot_value_t v[Z_SLOTS];
                memset(v, 0, sizeof v);
                v[Z_ZONE].kind = DS_SLOT_STRING;  v[Z_ZONE].v.s = name;
                v[Z_FROM].kind = DS_SLOT_INT;     v[Z_FROM].v.i = from;
                v[Z_UNTIL].kind = DS_SLOT_INT;    v[Z_UNTIL].v.i = until;
                v[Z_OFFSET].kind = DS_SLOT_INT;   v[Z_OFFSET].v.i = offset;
                int st = ds_engine_assert(e, rig->zone, v, Z_SLOTS, NULL).status;
                if (!assert_documented(st))
                    FAIL("ds_engine_assert answered a status libds.h does not document");
                if (st == DS_OK) zoned++;
            }
            free(name);
            if (!whole) return;
            break;
        }
        case OP_IDS: {
            size_t rl = 0, tl = 0;
            char *run_id = take_str(c, &rl);
            char *tier_id = run_id != NULL ? take_str(c, &tl) : NULL;
            if (tier_id != NULL) {
                rig_t next = { 0 };
                int   st;
                if (engine_up(run_id, tier_id, &next, &st) != NULL) {
                    pump(e);
                    ds_engine_free(e);
                    *rig = next;
                    wall_now = WALL_AT_SETUP;
                    named++;
                }
            }
            free(run_id);
            free(tier_id);
            if (tier_id == NULL) return;
            break;
        }
        }
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0) return 0;
    judged++;
    rig_t rig;
    int   st;
    wall_now = WALL_AT_SETUP;
    if (engine_up(NULL, NULL, &rig, &st) == NULL)
        FAIL("ds_engine_new refused an engine with no ids");

    cursor_t c = { data, size };
    run(&c, &rig);
    pump(rig.e);
    ds_engine_free(rig.e);
    return 0;
}

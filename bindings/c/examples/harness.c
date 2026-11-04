/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * harness.c -- the C binding's example: what an integrator's C code does to
 * drive libds, register a correct handler for every callback, and get every
 * lifetime right (who allocates, who frees, what is borrowed for the call).
 *
 * It is domain-agnostic and minimal. It loads a program of its own,
 * harness.ds, compiled by dsc, whose rules reach each callback a program
 * can reach. main() runs its stages in dependency order, each a function
 * named for what it does:
 *
 *     make_engine          create the engine, with a run id and a tier id
 *     register_callbacks   one logging handler per callback
 *     setup_clock          the mock clocks, so the run is deterministic
 *     capabilities         what this build carries, and what a load admits
 *     capacity             the cache caps
 *     load_program         harness.ds's schemas, services and rules
 *     program_metadata     sources, spans, rules and schemas as loaded
 *     program_services     the services the program declares, as a host
 *                          reads them
 *     seed_cache           a cache entry restored before the run
 *     inspect_schemas      count and find schemas
 *     assert_facts         one value of every kind, asserted
 *     read_facts           slots read back; live facts walked and counted
 *     fact_metadata        when a fact was asserted and expires, a
 *                          fact-ref slot's target, a fact's schema
 *     json_utilities       parse, path, serialize, clone, free
 *     run_program          a pump that fires the rules: log, cache, two
 *                          calls, a time-zone lookup and a fault
 *     answer_calls         each call answered: a response, or a CallError
 *     forward_fact         a clone of the engine, and the fact a call
 *                          carried asserted into it, as another tier would
 *     read_series          the series read in a rule's guard: no function
 *                          reads one
 *     forget               a cache entry deleted by a rule
 *     pump_and_ttl         advance the clock, pump the ttl sweep
 *     introspection        memory, rules, the Rete network, justifiers
 *     determinism_reads    the platform signature and session header
 *     check_reached       every callback the program reaches was reached
 *     teardown             retract, a fact gone, the halt latch, free
 *
 * It logs every call and its outcome to stdout, and every callback as it
 * runs; a failure goes to stderr and ends the run with EXIT_FAILURE. A run
 * that reaches the end prints "harness: OK".
 *
 * The c gate compiles it as strict C99 against libds.h, links it with
 * libds.a, compiles harness.ds with dsc, and runs it over the artefact
 * (bindings/c/C_STYLE.md). Against a libds release tarball, unpacked:
 *
 *   make -C bindings/c DS=/path/to/ds-libds-<version>-<os>-<arch> check
 *
 * bindings/c/Makefile says what it takes from the tarball.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

/* ------------------------------------------------------------------ */
/*  Logging                                                           */
/* ------------------------------------------------------------------ */

#define SEC(name) printf("\n== %s ==\n", (name))
#define LOG(...)                                                       \
    do {                                                               \
        printf("  ");                                                  \
        printf(__VA_ARGS__);                                           \
        printf("\n");                                                  \
    } while (0)

/* Report a failed call on stderr and end the run. `detail` is valid until
   the next libds call on the engine, so it is printed here, at once. */
static void fail(const char *what, ds_result_t r) {
    fprintf(stderr, "FAILED %s: status %d (%s)\n", what, (int) r.status,
            r.detail != NULL ? r.detail : "no detail");
    exit(EXIT_FAILURE);
}

/* A call that must succeed. */
static void must(const char *what, ds_result_t r) {
    if (r.status != DS_OK) {
        fail(what, r);
    }
    printf("  ok   %s\n", what);
}

/* A call whose failure is the expected outcome here: it must fail with
   exactly `want`, for the reason `why` gives. */
static void expect(const char *what, ds_result_t r, ds_status_t want,
                   const char *why) {
    if (r.status != want) {
        fprintf(stderr, "expected status %d from %s (%s)\n", (int) want,
                what, why);
        fail(what, r);
    }
    printf("  ok   %s -> status %d, as expected: %s\n", what,
           (int) r.status, why);
}

/* A value read back that must be what the program declares. */
static void check(bool ok, const char *what) {
    if (!ok) {
        fprintf(stderr, "FAILED %s\n", what);
        exit(EXIT_FAILURE);
    }
    printf("  ok   %s\n", what);
}

/* Whether a string the engine returned is `want`. */
static bool same(const char *got, const char *want) {
    return got != NULL && strcmp(got, want) == 0;
}

/* ------------------------------------------------------------------ */
/*  The run's state, carried to every handler by `user`               */
/* ------------------------------------------------------------------ */

#define MAX_PENDING 4
#define TEXT_MAX 64

/* A call the integrator owes an answer. The request's strings are valid
   for the callback only, so the handler copies what the answer needs. */
typedef struct pending_call {
    char service[TEXT_MAX];
    char correlation[TEXT_MAX];
    int64_t n;
} pending_call;

/* The log lines harness.ds's rules write, by their opening words: each
   must be seen once the program has run. "quotient " is the line the
   dividing rule would write had its division not trapped, and must not. */
static const char *const rule_logs[] = {
    "ping ", "counted ", "answered ", "unsupported ", "zoned ", "fault "
};
#define N_RULE_LOGS (sizeof rule_logs / sizeof rule_logs[0])
#define TRAPPED_LOG "quotient "

typedef struct harness_state {
    unsigned logs;
    bool rule_logged[N_RULE_LOGS];
    bool trapped_logged;
    unsigned calls;
    unsigned cache_sets;
    unsigned cache_deletes;
    pending_call pending[MAX_PENDING];
    uint32_t n_pending;
    /* The Ping a call carried as a fact argument: its FactExternal bytes,
       copied in the call callback (they are valid for it only), ours to
       free. */
    uint8_t *forwarded;
    size_t forwarded_len;
    /* The mock wall clock, which the harness sets and advances: a
       CallError's `ts` is when the integrator received the error
       ([LCRS.4.2.1]). */
    int64_t wall_ns;
} harness_state;

/* Copy a borrowed string into a sized buffer; false if it does not fit. */
static bool copy_text(char *dst, size_t size, const char *src) {
    int n = snprintf(dst, size, "%s", src);
    return n >= 0 && (size_t) n < size;
}

/* ------------------------------------------------------------------ */
/*  Callbacks: one handler per callback, each of the header's type.    */
/*  The program's rules reach the log, call and cache handlers.        */
/* ------------------------------------------------------------------ */

/* Every observable event, in seq order. The payload's pointers are valid
   for the callback only: copy what is kept. */
static ds_result_t on_stream(ds_engine_t *e, const ds_stream_ev_t *ev,
                             void *user) {
    uint64_t id = 0;
    ds_result_t r = DS_OK_R;
    (void) e;
    (void) user;
    switch (ev->kind) {
    case DS_EV_FACT_ASSERT:
        r = ds_fact_get_id(ev->p.fact_assert.fact, &id);
        if (r.status == DS_OK) {
            LOG("[stream] seq=%" PRIu64 " FACT_ASSERT fact=%" PRIu64,
                ev->seq, id);
        }
        break;
    case DS_EV_FACT_RETRACT:
        /* The fact is freed when this callback returns. */
        r = ds_fact_get_id(ev->p.fact_retract.fact, &id);
        if (r.status == DS_OK) {
            LOG("[stream] seq=%" PRIu64 " FACT_RETRACT fact=%" PRIu64,
                ev->seq, id);
        }
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        LOG("[stream] seq=%" PRIu64 " RULE_FIRE_BEGIN %s", ev->seq,
            ev->p.rule_fire_begin.rule_name);
        break;
    default:
        /* The kinds grow; a new one lands here. */
        LOG("[stream] seq=%" PRIu64 " kind=%d", ev->seq, (int) ev->kind);
        break;
    }
    if (r.status != DS_OK) {
        /* The handler's status is the engine's to act on. */
        fprintf(stderr, "on_stream: fact_get_id: status %d\n",
                (int) r.status);
    }
    return r;
}

/* A metric's kind says how to read its value: a counter's never falls, a
   gauge's may move either way. */
static ds_result_t on_metric(ds_engine_t *e, const ds_metric_t *m,
                             void *user) {
    (void) e;
    (void) user;
    LOG("[metric] %s %g (kind %d)", m->name, m->value, (int) m->kind);
    return DS_OK_R;
}

/* Advisory text: logged, never branched on. */
static ds_result_t on_log(ds_engine_t *e, const ds_log_event_t *ev,
                          void *user) {
    harness_state *h = user;
    size_t i;
    (void) e;
    h->logs++;
    for (i = 0; i < N_RULE_LOGS; i++) {
        if (strncmp(ev->message, rule_logs[i], strlen(rule_logs[i])) == 0) {
            h->rule_logged[i] = true;
        }
    }
    if (strncmp(ev->message, TRAPPED_LOG, strlen(TRAPPED_LOG)) == 0) {
        h->trapped_logged = true;
    }
    LOG("[log] level %d %s: %s", (int) ev->level, ev->category,
        ev->message);
    return DS_OK_R;
}

/* A `call` returns nothing to the rule. The integrator dispatches it and
   later asserts the response fact with this correlation, or a CallError
   ([NCBK.6.3]). The arguments are typed and sorted by name ([NCBK.6.10]);
   every string, and the correlation, is valid for the callback only, so
   what the answer needs is copied. The correlation is never NULL or
   empty: a call with no `as` carries a generated one ([LCCO.3.4]). */
static ds_result_t on_call(ds_engine_t *e, const ds_call_request_t *req,
                           void *user) {
    harness_state *h = user;
    pending_call *p;
    uint32_t i;
    (void) e;
    h->calls++;
    LOG("[call] %s corr=%s args=%" PRIu32, req->service, req->correlation,
        req->arg_count);
    if (h->n_pending == MAX_PENDING) {
        /* A non-OK status fails the pump that issued the call. */
        return DS_ERR_R(DS_ERR_OOM, "harness: no room for another call");
    }
    p = &h->pending[h->n_pending];
    p->n = 0;
    if (!copy_text(p->service, sizeof p->service, req->service)
        || !copy_text(p->correlation, sizeof p->correlation,
                      req->correlation)) {
        return DS_ERR_R(DS_ERR_OOM, "harness: a call's text is too long");
    }
    for (i = 0; i < req->arg_count; i++) {
        const ds_arg_t *a = &req->args[i];
        switch (a->value.kind) {
        case DS_ARG_INT:
            LOG("[call]   %s = %" PRId64, a->name, a->value.v.i);
            if (strcmp(a->name, "n") == 0) {
                p->n = a->value.v.i;
            }
            break;
        case DS_ARG_STRING:
            LOG("[call]   %s = \"%s\"", a->name, a->value.v.s);
            break;
        case DS_ARG_ENCODED_FACT: {
            /* Forward the bytes to another tier's
               ds_engine_assert_external; do not decode them. They are
               valid for the callback only, so the first is copied. */
            const ds_bytes_view_t *b = &a->value.v.fact.bytes;
            LOG("[call]   %s = a %s fact, %zu bytes", a->name,
                a->value.v.fact.schema, b->len);
            if (h->forwarded == NULL && b->len > 0) {
                h->forwarded = malloc(b->len);
                if (h->forwarded == NULL) {
                    return DS_ERR_R(DS_ERR_OOM, "harness: fact copy");
                }
                memcpy(h->forwarded, b->data, b->len);
                h->forwarded_len = b->len;
            }
            break;
        }
        default:
            LOG("[call]   %s (kind %d)", a->name, (int) a->value.kind);
            break;
        }
    }
    h->n_pending++;
    return DS_OK_R;
}

/* A cache write, for a persisting store. The value is borrowed for the
   callback; DS_CACHE_TTL_NONE means no expiry. The engine's own cache has
   already changed and does not roll back on a hook failure. */
static ds_result_t on_cache_set(ds_engine_t *e, const ds_cache_write_t *wr,
                                void *user) {
    harness_state *h = user;
    (void) e;
    h->cache_sets++;
    LOG("[cache_set] %s ttl_ns=%" PRIu64, wr->key, wr->ttl_ns);
    return DS_OK_R;
}

/* An entry left the cache: deleted, or its ttl passed. */
static ds_result_t on_cache_delete(ds_engine_t *e,
                                   const ds_cache_removal_t *rm,
                                   void *user) {
    harness_state *h = user;
    (void) e;
    h->cache_deletes++;
    LOG("[cache_delete] %s reason %d", rm->key, (int) rm->reason);
    return DS_OK_R;
}

/* ------------------------------------------------------------------ */
/*  Introspection callbacks: read-only. Their strings are valid for    */
/*  the callback only, and a libds call on this engine from inside one */
/*  returns DS_ERR_STATE.                                              */
/* ------------------------------------------------------------------ */

/* A counter the stage reads back, carried by `user`. */
static void count_node(const char *id, const char *kind, const char *label,
                       const char *filter, uint32_t occupancy,
                       bool is_negative, void *user) {
    (void) id;
    (void) kind;
    (void) label;
    (void) filter;
    (void) occupancy;
    (void) is_negative;
    (*(unsigned *) user)++;
}

static void count_edge(const char *from, const char *to, void *user) {
    (void) from;
    (void) to;
    (*(unsigned *) user)++;
}

static void on_trace(const char *node_id, const char *node_kind,
                     const char *result, const char *detail, void *user) {
    (void) user;
    LOG("[trace] %s %s: %s (%s)", node_kind, node_id, result, detail);
}

static void on_refract(const char *rule_name, const char *reason,
                       const char *detail, const uint64_t *fact_ids,
                       uint32_t fact_count, void *user) {
    (void) detail;
    (void) fact_ids;
    (void) user;
    LOG("[refract] %s: %s, %" PRIu32 " facts", rule_name, reason,
        fact_count);
}

/* A fact visitor. Every libds call on this engine from inside it returns
   DS_ERR_STATE, so it only counts, through `user`. */
static ds_result_t count_fact(const ds_fact_t *f, void *user) {
    (void) f;
    (*(size_t *) user)++;
    return DS_OK_R;
}

/* ------------------------------------------------------------------ */
/*  Stages                                                            */
/* ------------------------------------------------------------------ */

/* The engine, with a run id and a tier id. They are the integrator's to
   give and to mean; the engine copies them, derives every fact's event_id
   from them, and mints no identity of its own ([NLFC.1.2]). */
static ds_engine_t *make_engine(void) {
    ds_engine_t *e = NULL;
    ds_engine_config_t cfg = {0};
    const char *run_id = NULL;
    const char *tier_id = NULL;
    SEC("engine");
    cfg.run_id = "harness-run";
    cfg.tier_id = "edge";
    must("ds_engine_new", ds_engine_new(&cfg, &e));
    /* The engine's own copies, valid for its life. */
    must("get_run_id", ds_engine_get_run_id(e, &run_id));
    must("get_tier_id", ds_engine_get_tier_id(e, &tier_id));
    if (run_id == NULL || strcmp(run_id, "harness-run") != 0
        || tier_id == NULL || strcmp(tier_id, "edge") != 0) {
        fprintf(stderr, "FAILED: the engine's ids are not the ones given\n");
        exit(EXIT_FAILURE);
    }
    LOG("run %s, tier %s", run_id, tier_id);
    return e;
}

/* Every callback, before anything observable happens. The handlers whose
   counts check_reached reads are given the run's state as `user`. */
static void register_callbacks(ds_engine_t *e, harness_state *h) {
    SEC("callbacks");
    must("set_stream_callback",
         ds_engine_set_stream_callback(e, on_stream, NULL));
    must("set_metric_callback",
         ds_engine_set_metric_callback(e, on_metric, NULL));
    must("set_log_callback", ds_engine_set_log_callback(e, on_log, h));
    must("set_call_callback", ds_engine_set_call_callback(e, on_call, h));
    /* The cache is the engine's. These are optional persistence hooks, and
       the version is the one this file was compiled against. */
    must("cache_callbacks",
         ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, on_cache_set,
                                   on_cache_delete, h));
}

/* 2026-01-01T00:00:00Z, in nanoseconds since the Unix epoch. */
#define WALL_START INT64_C(1767225600000000000)

/* The mock clocks move only when told to. The monotonic clock starts at 0;
   the wall clock is set to WALL_START, and clock_advance moves both. The
   switch must come before the engine first samples its clock, for an input
   or a pump. */
static void setup_clock(ds_engine_t *e, harness_state *h) {
    uint64_t now = 0;
    ds_clock_mode_t mode = DS_CLOCK_LIVE;
    SEC("clock");
    must("clock_set_mode(MOCK)", ds_engine_clock_set_mode(e, DS_CLOCK_MOCK));
    must("clock_mode", ds_engine_clock_mode(e, &mode));
    if (mode != DS_CLOCK_MOCK) {
        fprintf(stderr, "FAILED: the clock is not in mock mode\n");
        exit(EXIT_FAILURE);
    }
    must("clock_set(0)", ds_engine_clock_set(e, 0));
    must("wall_clock_set", ds_engine_wall_clock_set(e, WALL_START));
    h->wall_ns = WALL_START;
    must("clock_now", ds_engine_clock_now(e, &now));
    LOG("monotonic clock at %" PRIu64 " ns, wall clock at %" PRId64 " ns",
        now, h->wall_ns);
}

/* Both clocks forward by `delta_ns`, and the harness's copy of the wall. */
static void advance(ds_engine_t *e, harness_state *h, uint64_t delta_ns) {
    must("clock_advance", ds_engine_clock_advance(e, delta_ns));
    /* delta_ns is at most a few minutes here, well inside int64_t. */
    h->wall_ns += (int64_t) delta_ns;
}

#define MAX_CAPABILITIES 32

/* What this build of libds has code for, and the admission policy of this
   integration, both before a load ([NLFC.10.1], [NLFC.10.2]). The policy
   admits only programs that are not realtime: this integration has no
   realtime support, whatever the build carries, and harness.ds is not
   one. */
static void capabilities(ds_engine_t *e) {
    ds_capability_t caps[MAX_CAPABILITIES];
    size_t n;
    size_t i;
    SEC("capabilities");
    /* Called with no array first, to size one; it needs no engine. */
    n = ds_build_capabilities(NULL, 0);
    if (n > MAX_CAPABILITIES) {
        fprintf(stderr, "FAILED: %zu capabilities, room for %d\n", n,
                MAX_CAPABILITIES);
        exit(EXIT_FAILURE);
    }
    (void) ds_build_capabilities(caps, n);  /* the same count, known */
    for (i = 0; i < n; i++) {
        LOG("this build carries capability %d", (int) caps[i]);
    }
    must("set_admission(REALTIME, FALSE_ONLY)",
         ds_engine_set_admission(e, DS_CAPABILITY_REALTIME,
                                 DS_ADMIT_FALSE_ONLY));
}

/* The cache caps, before a load: they bound keys and value bytes, 0 for
   unbounded. This edition has no working-memory bound and no pool sizing:
   both return with realtime ([NRTM.3.1], [NRTM.9.1]). */
static void capacity(ds_engine_t *e) {
    SEC("capacity");
    must("set_cache_cap(64 keys, unbounded bytes)",
         ds_engine_set_cache_cap(e, 64, 0));
}

/* The program, read from the .dsc file dsc wrote and loaded. A load
   registers the schemas, services and rules the source declares
   ([NGST.4.2]), and is the only way a schema reaches the engine; it comes
   before the engine's first stream event ([NFCT.1.1]). The bytes are not
   retained by the load, so they are freed once it returns. */
static void load_program(ds_engine_t *e, const char *path) {
    FILE *f;
    uint8_t *bytes;
    long size = 0;
    size_t got;
    ds_result_t r;

    SEC("load the program");
    f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "FAILED fopen %s\n", path);
        exit(EXIT_FAILURE);
    }
    if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) <= 0
        || fseek(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "FAILED reading the size of %s\n", path);
        (void) fclose(f);   /* the run ends: nothing to do with its result */
        exit(EXIT_FAILURE);
    }
    /* size is positive, so the conversion loses nothing. */
    bytes = malloc((size_t) size);
    if (bytes == NULL) {
        fprintf(stderr, "FAILED malloc of %ld bytes\n", size);
        (void) fclose(f);   /* the run ends: nothing to do with its result */
        exit(EXIT_FAILURE);
    }
    got = fread(bytes, 1, (size_t) size, f);
    if (fclose(f) != 0 || got != (size_t) size) {
        fprintf(stderr, "FAILED reading %s\n", path);
        free(bytes);
        exit(EXIT_FAILURE);
    }
    LOG("%s: %zu bytes", path, got);
    r = ds_engine_load_dsc(e, bytes, got);
    free(bytes);
    must("load_dsc", r);
}

/* A schema by name, which must exist. The pointer is the engine's, valid
   for its life. */
static const ds_schema_t *find_schema(ds_engine_t *e, const char *name) {
    const ds_schema_t *found = NULL;
    must("schema_find", ds_engine_schema_find(e, name, &found));
    if (found == NULL) {
        fprintf(stderr, "FAILED schema_find %s: no such schema\n", name);
        exit(EXIT_FAILURE);
    }
    return found;
}

/* Schemas read back by name: one a rule reads and one only the integrator
   asserts. The names are the engine's, valid for its life. */
static void inspect_schemas(ds_engine_t *e) {
    static const char *const names[2] = { "Demo", "Ping" };
    size_t n = 0;
    const char *name = NULL;
    uint32_t slots = 0;
    int i;
    SEC("schema introspection");
    must("schema_count", ds_engine_schema_count(e, &n));
    LOG("%zu schemas registered", n);
    for (i = 0; i < 2; i++) {
        const ds_schema_t *found = find_schema(e, names[i]);
        must("schema_get_name", ds_schema_get_name(found, &name));
        must("schema_get_slot_count",
             ds_schema_get_slot_count(found, &slots));
        LOG("'%s' has %" PRIu32 " slots", name, slots);
    }
}

/* What the load put on the engine for tools: every schema by index, a
   schema's source position and generated .proto text, a rule's metadata,
   the program's source text and its Rete-node spans. Every string is the
   engine's, valid for its life. A built-in schema has no source position:
   its file is NULL. */
static void program_metadata(ds_engine_t *e) {
    size_t n = 0;
    size_t i;
    const char *file = NULL;
    uint32_t line = 0;
    uint32_t col = 0;
    const char *proto = NULL;
    size_t proto_len = 0;
    ds_rule_meta_view_t rule;
    bool found = false;
    ds_ds_source_view_t src;
    ds_line_span_view_t span;
    ds_line_span_view_t again;

    SEC("program metadata");
    must("schema_count", ds_engine_schema_count(e, &n));
    for (i = 0; i < n; i++) {
        const ds_schema_t *s = NULL;
        const char *name = NULL;
        must("schema_at", ds_engine_schema_at(e, i, &s));
        must("schema_get_name", ds_schema_get_name(s, &name));
        LOG("schema %zu: %s", i, name);
    }

    must("schema_get_source Ping",
         ds_schema_get_source(find_schema(e, "Ping"), &file, &line, &col));
    if (file == NULL) {
        fprintf(stderr, "FAILED: a loaded schema has no source\n");
        exit(EXIT_FAILURE);
    }
    LOG("Ping is declared at %s:%" PRIu32 ":%" PRIu32, file, line, col);
    must("schema_get_proto_source Ping",
         ds_schema_get_proto_source(find_schema(e, "Ping"), &proto,
                                    &proto_len));
    LOG("Ping's .proto text: %zu bytes", proto != NULL ? proto_len : 0);
    must("schema_get_source ComputationError",
         ds_schema_get_source(find_schema(e, "ComputationError"), &file,
                              NULL, NULL));
    LOG("ComputationError, built in, %s", file == NULL ? "has no source"
                                                      : "has a source");

    must("rule_meta_find pinged",
         ds_engine_rule_meta_find(e, "pinged", &rule, &found));
    if (!found) {
        fprintf(stderr, "FAILED: no metadata for rule pinged\n");
        exit(EXIT_FAILURE);
    }
    if (rule.has_srcr) {
        LOG("rule %s at %s:%" PRIu32, rule.rule_name, rule.src_file,
            rule.src_line);
    }

    must("ds_source_count", ds_engine_ds_source_count(e, &n));
    if (n == 0) {
        fprintf(stderr, "FAILED: the program carries no source text\n");
        exit(EXIT_FAILURE);
    }
    must("ds_source_at(0)", ds_engine_ds_source_at(e, 0, &src));
    /* The text is length-delimited; it is not printed as a string. */
    LOG("source %" PRIu32 ": %s, %zu bytes", src.module_id, src.file,
        src.text_len);

    must("line_span_count", ds_engine_line_span_count(e, &n));
    if (n == 0) {
        fprintf(stderr, "FAILED: the program maps no node to a line\n");
        exit(EXIT_FAILURE);
    }
    must("line_span_at(0)", ds_engine_line_span_at(e, 0, &span));
    must("line_span_find", ds_engine_line_span_find(e, span.node_id, &again));
    LOG("node %" PRIu32 " is at %s:%" PRIu32 ":%" PRIu32, again.node_id,
        again.ds_file, again.ds_line, again.ds_col);
}

/* The services the program declares, as an integrator that hosts them reads
   them: what to assert for a call, a fact of the response schema or nothing
   for a `no response` service ([NDBG.2.4]). Services come in source order
   ([RDSC.8.4]), each one's kwargs in name order ([LGRA.23.2]). Every string
   and each kwarg array are the engine's, valid for its life. */
static void program_services(ds_engine_t *e) {
    static const char *const declared[3] = {
        "svc.echo", "svc.absent", "svc.notify"
    };
    size_t n = 0;
    size_t i;
    uint32_t k;
    ds_service_view_t svc;
    bool found = false;

    SEC("program services");
    must("service_count", ds_engine_service_count(e, &n));
    check(n == 3, "harness.ds declares three services");
    for (i = 0; i < n; i++) {
        must("service_at", ds_engine_service_at(e, i, &svc));
        LOG("service %zu: %s, %s %s, %" PRIu32 " kwargs", i, svc.name,
            svc.no_response ? "no response" : "response",
            svc.response, svc.kwarg_count);
        for (k = 0; k < svc.kwarg_count; k++) {
            LOG("  kwarg %s: %s%s", svc.kwargs[k].name,
                svc.kwargs[k].ds_type,
                svc.kwargs[k].required ? " required" : "");
        }
        check(same(svc.name, declared[i]),
              "the services are in the order harness.ds writes them");
    }
    expect("service_at (past the count)", ds_engine_service_at(e, n, &svc),
           DS_ERR_NOT_FOUND, "the index names no service");

    must("service_find svc.echo",
         ds_engine_service_find(e, "svc.echo", &svc, &found));
    check(found, "svc.echo is found");
    check(same(svc.response, "Reply") && !svc.no_response,
          "svc.echo responds with a Reply");
    check(svc.kwarg_count == 2, "svc.echo has two kwargs");
    check(same(svc.kwargs[0].name, "n") && same(svc.kwargs[0].ds_type, "Int")
          && svc.kwargs[0].required,
          "its first kwarg is n: Int, required");
    check(same(svc.kwargs[1].name, "ping")
          && same(svc.kwargs[1].ds_type, "Ping") && !svc.kwargs[1].required,
          "its second is ping: Ping, optional, though written first");

    must("service_find svc.notify",
         ds_engine_service_find(e, "svc.notify", &svc, &found));
    check(found, "svc.notify is found");
    check(svc.no_response && same(svc.response, "") && svc.kwarg_count == 0,
          "svc.notify declares no response and takes no kwargs");

    /* A miss is not an error: DS_OK, and *found false. */
    found = true;
    must("service_find svc.undeclared",
         ds_engine_service_find(e, "svc.undeclared", &svc, &found));
    check(!found, "an undeclared service is not found");
}

/* A cache entry restored before the run, as from write-through persistence
   on startup ([LSTO.4.5.2]). A seed is not a rule's write: it emits no
   event and reaches no write-through hook. It is set-up only, before the
   first pump. The engine copies the tree, which stays ours to free. */
static void seed_cache(ds_engine_t *e) {
    static const char text[] = "{\"restored\":true}";
    ds_json_t *value = NULL;
    SEC("seed the cache");
    must("json_parse (the seed, ours)",
         ds_json_parse(text, sizeof text - 1, &value));
    must("cache_seed restored",
         ds_engine_cache_seed(e, "restored", value, DS_CACHE_TTL_NONE));
    must("json_free (the seed)", ds_json_free(value));
}

/* The ids of the facts the integrator asserts. A fact pointer is not kept
   across a pump; an id is, and finds the fact again. */
typedef struct fact_ids {
    uint64_t ref;
    uint64_t demo;
    uint64_t ev;
} fact_ids;

/* One value of every kind, asserted. The engine copies a Json slot's tree
   during the assert, so the tree stays the caller's to free. */
static fact_ids assert_facts(ds_engine_t *e) {
    const ds_schema_t *ref = find_schema(e, "Ref");
    const ds_schema_t *demo = find_schema(e, "Demo");
    const ds_schema_t *ev = find_schema(e, "Ev");
    static const char doc_text[] = "{\"a\":1,\"b\":[true,null]}";
    static const uint8_t raw[] = { 0x00, 0x01, 0x02, 0x03 };
    ds_json_t *doc = NULL;
    ds_slot_value_t ref_vals[1];
    ds_slot_value_t demo_vals[7];
    ds_slot_value_t ev_vals[1];
    ds_fact_t *ref_fact = NULL;
    ds_fact_t *demo_fact = NULL;
    ds_fact_t *ev_fact = NULL;
    fact_ids ids = { 0, 0, 0 };

    SEC("assert facts");
    must("json_parse (the doc slot's tree, ours)",
         ds_json_parse(doc_text, sizeof doc_text - 1, &doc));

    ref_vals[0].kind = DS_SLOT_INT;
    ref_vals[0].v.i = 1;
    must("assert Ref", ds_engine_assert(e, ref, ref_vals, 1, &ref_fact));
    must("fact_get_id Ref", ds_fact_get_id(ref_fact, &ids.ref));

    demo_vals[0].kind = DS_SLOT_STRING;
    demo_vals[0].v.s = "first";
    demo_vals[1].kind = DS_SLOT_INT;
    demo_vals[1].v.i = 42;
    demo_vals[2].kind = DS_SLOT_FLOAT;
    demo_vals[2].v.f = 3.5;
    demo_vals[3].kind = DS_SLOT_BOOL;
    demo_vals[3].v.b = true;
    demo_vals[4].kind = DS_SLOT_BYTES;
    demo_vals[4].v.bytes.data = raw;
    demo_vals[4].v.bytes.len = sizeof raw;
    demo_vals[5].kind = DS_SLOT_JSON;
    demo_vals[5].v.json = doc;
    demo_vals[6].kind = DS_SLOT_FACT_REF;
    demo_vals[6].v.ref = ref_fact;
    must("assert Demo", ds_engine_assert(e, demo, demo_vals, 7, &demo_fact));
    must("fact_get_id Demo", ds_fact_get_id(demo_fact, &ids.demo));

    /* A ttl fact: its deadline is its schema's 1 s. */
    ev_vals[0].kind = DS_SLOT_STRING;
    ev_vals[0].v.s = "e";
    must("assert Ev (ttl 1 s)", ds_engine_assert(e, ev, ev_vals, 1, &ev_fact));
    must("fact_get_id Ev", ds_fact_get_id(ev_fact, &ids.ev));

    must("json_free (the doc slot's tree)", ds_json_free(doc));
    return ids;
}

/* When a fact was asserted, when it expires, the schema it instantiates,
   and the target of a fact-ref slot, by id: an id identifies its fact even
   after the fact has gone. Each fact is found again by id. */
static void fact_metadata(ds_engine_t *e, const fact_ids *ids) {
    ds_fact_t *fact = NULL;
    const ds_schema_t *schema = NULL;
    const char *name = NULL;
    uint64_t asserted = 0;
    uint64_t deadline = 0;
    uint64_t target = 0;

    SEC("fact metadata");
    must("fact_find Ev", ds_engine_fact_find(e, ids->ev, &fact));
    must("fact_get_asserted_ns", ds_fact_get_asserted_ns(fact, &asserted));
    must("fact_get_ttl_deadline_ns",
         ds_fact_get_ttl_deadline_ns(fact, &deadline));
    /* The schema's ttl: 1 s after the assert. */
    if (deadline != asserted + UINT64_C(1000000000)) {
        fprintf(stderr, "FAILED: Ev's deadline is %" PRIu64 ", asserted at %"
                PRIu64 "\n", deadline, asserted);
        exit(EXIT_FAILURE);
    }
    LOG("Ev asserted at %" PRIu64 " ns, expires at %" PRIu64 " ns",
        asserted, deadline);

    must("fact_find Demo", ds_engine_fact_find(e, ids->demo, &fact));
    must("fact_get_schema", ds_fact_get_schema(fact, &schema));
    must("schema_get_name", ds_schema_get_name(schema, &name));
    /* Slot 6 is `link`, which refers to the Ref fact. An explicit fact has
       no ttl deadline. */
    must("fact_get_slot_ref_id link", ds_fact_get_slot_ref_id(fact, 6,
                                                               &target));
    must("fact_get_ttl_deadline_ns",
         ds_fact_get_ttl_deadline_ns(fact, &deadline));
    if (target != ids->ref || deadline != 0) {
        fprintf(stderr, "FAILED: link names %" PRIu64 ", want %" PRIu64
                "; deadline %" PRIu64 ", want 0\n", target, ids->ref,
                deadline);
        exit(EXIT_FAILURE);
    }
    LOG("a %s fact, whose link names fact %" PRIu64, name, target);
}

/* A fact's slots read back, then every live fact walked and counted. The
   fact pointer is found again by id, and is valid until the fact is
   retracted; a string or bytes read from it lives as long. */
static void read_facts(ds_engine_t *e, uint64_t demo_id) {
    ds_fact_t *fact = NULL;
    uint32_t n = 0;
    uint32_t i;
    size_t walked = 0;
    size_t live = 0;

    SEC("read facts");
    must("fact_find Demo", ds_engine_fact_find(e, demo_id, &fact));
    must("fact_get_slot_count", ds_fact_get_slot_count(fact, &n));
    for (i = 0; i < n; i++) {
        const char *name = NULL;
        ds_slot_value_t v;
        must("fact_get_slot", ds_fact_get_slot(fact, i, &name, &v));
        switch (v.kind) {
        case DS_SLOT_INT:
            LOG("%s = %" PRId64, name, v.v.i);
            break;
        case DS_SLOT_FLOAT:
            LOG("%s = %g", name, v.v.f);
            break;
        case DS_SLOT_STRING:
            LOG("%s = \"%s\"", name, v.v.s);
            break;
        case DS_SLOT_BOOL:
            LOG("%s = %s", name, v.v.b ? "true" : "false");
            break;
        case DS_SLOT_BYTES:
            LOG("%s = %zu bytes", name, v.v.bytes.len);
            break;
        default:
            LOG("%s (kind %d)", name, (int) v.kind);
            break;
        }
    }
    must("for_each_fact",
         ds_engine_for_each_fact(e, NULL, count_fact, &walked));
    must("fact_count", ds_engine_fact_count(e, &live));
    LOG("walked %zu of %zu live facts", walked, live);
}

/* The Json utilities, and who owns each result. */
static void json_utilities(void) {
    static const char text_in[] = "{\"k\":\"v\"}";
    ds_json_t *parsed = NULL;
    ds_json_t *clone = NULL;
    const ds_json_t *leaf = NULL;
    char *text = NULL;
    size_t len = 0;

    SEC("json");
    must("json_parse (ours)",
         ds_json_parse(text_in, sizeof text_in - 1, &parsed));
    /* A borrow into `parsed`: never freed on its own. */
    must("json_get_path k (borrowed)", ds_json_get_path(parsed, "k", &leaf));
    /* The text is ours, and released with ds_free, not free. */
    must("json_serialize", ds_json_serialize(parsed, &text, &len));
    LOG("serialized %zu bytes: %s", len, text);
    ds_free(text);
    must("json_clone (ours)", ds_json_clone(parsed, &clone));
    must("json_free (the clone)", ds_json_free(clone));
    must("json_free (the parsed tree)", ds_json_free(parsed));
}

/* One slot's value, given by the slot's name. */
typedef struct named_value {
    const char *name;
    ds_slot_value_t value;
} named_value;

#define MAX_SLOTS 8

/* Assert a fact of a program's schema. ds_engine_assert takes the values
   in the schema's declaration order, which is the program's, so each value
   is placed by its slot's name as the engine reports it. Every slot must
   be given, and only those. */
static void assert_named(ds_engine_t *e, const char *schema_name,
                         const named_value *given, uint32_t n_given) {
    const ds_schema_t *schema = find_schema(e, schema_name);
    ds_slot_value_t values[MAX_SLOTS];
    char what[TEXT_MAX];
    uint32_t n = 0;
    uint32_t i;
    uint32_t j;
    int len;

    must("schema_get_slot_count", ds_schema_get_slot_count(schema, &n));
    if (n != n_given || n > MAX_SLOTS) {
        fprintf(stderr, "FAILED %s: %" PRIu32 " slots, %" PRIu32
                " values given\n", schema_name, n, n_given);
        exit(EXIT_FAILURE);
    }
    for (i = 0; i < n; i++) {
        ds_slot_desc_t slot;
        bool placed = false;
        must("schema_get_slot", ds_schema_get_slot(schema, i, &slot));
        for (j = 0; j < n_given && !placed; j++) {
            if (strcmp(slot.name, given[j].name) == 0) {
                values[i] = given[j].value;
                placed = true;
            }
        }
        if (!placed) {
            fprintf(stderr, "FAILED %s: no value for slot %s\n",
                    schema_name, slot.name);
            exit(EXIT_FAILURE);
        }
    }
    len = snprintf(what, sizeof what, "assert %s", schema_name);
    if (len < 0 || (size_t) len >= sizeof what) {
        fprintf(stderr, "FAILED snprintf: schema name too long\n");
        exit(EXIT_FAILURE);
    }
    must(what, ds_engine_assert(e, schema, values, n, NULL));
}

/* A Reading's slots: the key "r1", `x` and `tag`. */
static void assert_reading(ds_engine_t *e, double x, const char *tag) {
    named_value reading[3];
    reading[0].name = "id";
    reading[0].value.kind = DS_SLOT_STRING;
    reading[0].value.v.s = "r1";
    reading[1].name = "x";
    reading[1].value.kind = DS_SLOT_FLOAT;
    reading[1].value.v.f = x;
    reading[2].name = "tag";
    reading[2].value.kind = DS_SLOT_STRING;
    reading[2].value.v.s = tag;
    assert_named(e, "Reading", reading, 3);
}

/* A Ping, a Reading and a Pair, then a pump. The pump fires harness.ds's
   rules: a log line, a cache write, a call to each service, and a division
   by zero; then the series absorbs the Reading's sample. The division
   traps: its activation is abandoned, the fault reaches the stream
   callback, and the ComputationError fact asserted after it fires
   `faulted` ([LERR.9.1]). */
static void run_program(ds_engine_t *e) {
    named_value ping[2];
    named_value pair[3];
    named_value stamp[3];
    named_value zone[4];

    SEC("run the program");
    /* libds carries no zone data ([LTIM.10.1]): a zone's offsets are facts
       of the built-in TimeZoneOffset, each one zone's offset over one period
       [valid_from, valid_until) ([LTIM.10.6]). This harness knows one zone,
       "Test/Ahead", an hour ahead over the longest period a row can state.
       With no row for it, `zoned` would fault and not fire, never read as
       UTC ([LTIM.10.5]). */
    zone[0].name = "zone";
    zone[0].value.kind = DS_SLOT_STRING;
    zone[0].value.v.s = "Test/Ahead";
    zone[1].name = "valid_from";
    zone[1].value.kind = DS_SLOT_INT;
    zone[1].value.v.i = INT64_MIN;
    zone[2].name = "valid_until";
    zone[2].value.kind = DS_SLOT_INT;
    zone[2].value.v.i = INT64_MAX;
    zone[3].name = "offset_s";
    zone[3].value.kind = DS_SLOT_INT;
    zone[3].value.v.i = 3600;
    assert_named(e, "TimeZoneOffset", zone, 4);
    /* 23:30 UTC on 2026-01-01, and 2026-01-02 as days since the epoch:
       its date an hour ahead of UTC. A Time and a Date are Ints. */
    stamp[0].name = "id";
    stamp[0].value.kind = DS_SLOT_STRING;
    stamp[0].value.v.s = "s1";
    stamp[1].name = "instant";
    stamp[1].value.kind = DS_SLOT_INT;
    stamp[1].value.v.i = WALL_START + INT64_C(84600000000000);
    stamp[2].name = "day";
    stamp[2].value.kind = DS_SLOT_INT;
    stamp[2].value.v.i = 20455;
    assert_named(e, "Stamp", stamp, 3);

    ping[0].name = "id";
    ping[0].value.kind = DS_SLOT_STRING;
    ping[0].value.v.s = "p1";
    ping[1].name = "n";
    ping[1].value.kind = DS_SLOT_INT;
    ping[1].value.v.i = 21;
    assert_named(e, "Ping", ping, 2);
    assert_reading(e, 1.5, "low");

    pair[0].name = "id";
    pair[0].value.kind = DS_SLOT_STRING;
    pair[0].value.v.s = "q";
    pair[1].name = "a";
    pair[1].value.kind = DS_SLOT_INT;
    pair[1].value.v.i = 1;
    pair[2].name = "b";
    pair[2].value.kind = DS_SLOT_INT;
    pair[2].value.v.i = 0;
    assert_named(e, "Pair", pair, 3);

    must("pump", ds_engine_pump(e));
}

/* Each call the pump issued, answered after it, as a host serves a
   service ([NCBK.6.3]): svc.echo with its response, a Reply carrying the
   call's correlation, and a service nobody hosts with a CallError coded
   request.unsupported ([LECC.3.1.1]), whose `ts` is when the error was
   received. A pump then fires the rules that match the answers. */
static void answer_calls(ds_engine_t *e, harness_state *h) {
    uint32_t i;

    SEC("answer the calls");
    for (i = 0; i < h->n_pending; i++) {
        const pending_call *p = &h->pending[i];
        named_value v[4];
        v[0].name = "corr";
        v[0].value.kind = DS_SLOT_STRING;
        v[0].value.v.s = p->correlation;
        if (strcmp(p->service, "svc.echo") == 0) {
            v[1].name = "doubled";
            v[1].value.kind = DS_SLOT_INT;
            v[1].value.v.i = 2 * p->n;
            assert_named(e, "Reply", v, 2);
        } else {
            v[1].name = "code";
            v[1].value.kind = DS_SLOT_STRING;
            v[1].value.v.s = "request.unsupported";
            v[2].name = "message";
            v[2].value.kind = DS_SLOT_STRING;
            v[2].value.v.s = "no host offers this service";
            /* A Time slot's value is an Int: nanoseconds since the
               epoch. */
            v[3].name = "ts";
            v[3].value.kind = DS_SLOT_INT;
            v[3].value.v.i = h->wall_ns;
            assert_named(e, "CallError", v, 4);
        }
    }
    h->n_pending = 0;
    must("pump (the answers)", ds_engine_pump(e));
}

/* Another tier, as a clone of this engine: identical now, independent from
   here on, and starting with no callbacks ([NLFC.8.3]). The Ping that
   svc.echo's call carried as a fact argument is asserted into it, as a
   tier receiving a published fact does ([NCBK.10.4]): the bytes are
   forwarded, never decoded. The clone already holds that Ping, so the
   assert is a no-op reassertion, and nothing it does reaches this
   engine. */
static void forward_fact(ds_engine_t *e, harness_state *h) {
    ds_engine_t *tier = NULL;
    size_t live = 0;
    SEC("forward a fact to another tier");
    if (h->forwarded == NULL) {
        fprintf(stderr, "FAILED: no call carried a fact argument\n");
        exit(EXIT_FAILURE);
    }
    /* Ours to free, in either order with the source. */
    must("ds_engine_clone", ds_engine_clone(e, &tier));
    must("assert_external (the forwarded Ping)",
         ds_engine_assert_external(tier, h->forwarded, h->forwarded_len));
    must("fact_count (the clone)", ds_engine_fact_count(tier, &live));
    LOG("the clone holds %zu live facts", live);
    must("ds_engine_free (the clone)", ds_engine_free(tier));
    free(h->forwarded);
    h->forwarded = NULL;
}

/* No function reads a series ([NSBK.6.3]): a rule reads one. A
   series keeps its state per identity, and Reading's one key slot, `id`,
   is the identity it follows ([LSER.7.6.1]). The series absorbed the first
   Reading's sample after the agenda drained ([LSER.8.6.5]), so `counted`'s
   guard, which saw none on the first arrival, sees count(r.x) and
   count_of(r.tag, "low") at 1 each on the update, and fires: check_reached
   reads its "counted " line. */
static void read_series(ds_engine_t *e) {
    SEC("the series, read by a rule");
    assert_reading(e, 2.5, "high");
    must("pump", ds_engine_pump(e));
}

/* A Forget, whose rule deletes the cache entry `pinged` wrote. */
static void forget(ds_engine_t *e) {
    named_value f[1];
    SEC("forget");
    f[0].name = "id";
    f[0].value.kind = DS_SLOT_STRING;
    f[0].value.v.s = "f";
    assert_named(e, "Forget", f, 1);
    must("pump", ds_engine_pump(e));
}

/* 2 s of mock time and a pump, whose ttl sweep takes Ev out. */
static void pump_and_ttl(ds_engine_t *e, harness_state *h) {
    SEC("ttl");
    advance(e, h, UINT64_C(2000000000));
    must("pump (the ttl sweep)", ds_engine_pump(e));
}

/* Read-only introspection over the loaded program. */
static void introspection(ds_engine_t *e) {
    ds_engine_mem_t mem;
    size_t rules = 0;
    size_t sources = 0;
    size_t spans = 0;
    unsigned nodes = 0;
    unsigned edges = 0;
    int64_t *timetags = NULL;
    char **names = NULL;
    uint32_t n = 0;
    uint32_t i;

    SEC("introspection");
    must("ds_engine_mem", ds_engine_mem(e, &mem));
    LOG("%zu live facts, %zu bytes in use", mem.wm_fact_count,
        mem.total_bytes);
    must("rule_meta_count", ds_engine_rule_meta_count(e, &rules));
    LOG("%zu rules", rules);
    must("rete_network",
         ds_engine_rete_network(e, NULL, false, count_node, &nodes,
                                count_edge, &edges));
    LOG("Rete network: %u nodes, %u edges", nodes, edges);
    must("rete_match_trace (no such fact)",
         ds_engine_rete_match_trace(e, 0, on_trace, NULL));
    must("refracted_activations",
         ds_engine_refracted_activations(e, NULL, on_refract, NULL));
    must("ds_source_count", ds_engine_ds_source_count(e, &sources));
    must("line_span_count", ds_engine_line_span_count(e, &spans));
    LOG("%zu sources, %zu spans", sources, spans);

    /* Both arrays and every name are ours, each released with ds_free. */
    must("get_justifiers (no such fact)",
         ds_engine_get_justifiers(e, 0, &timetags, &names, &n));
    LOG("%" PRIu32 " justifiers", n);
    for (i = 0; i < n; i++) {
        ds_free(names[i]);
    }
    ds_free(names);
    ds_free(timetags);
}

/* The platform signature and session header. Their strings are static or
   the engine's; copy what is kept past the engine. */
static void determinism_reads(ds_engine_t *e) {
    ds_platform_signature_t sig;
    ds_session_header_t hdr;
    SEC("determinism reads");
    must("platform_signature", ds_engine_get_platform_signature(e, &sig));
    LOG("%s/%s %s %s, libds %s, %zu series backends", sig.os_family,
        sig.cpu_arch, sig.libc, sig.compiler, sig.libds_version,
        sig.n_backends);
    must("session_header", ds_engine_get_session_header(e, &hdr));
    LOG("ds_version %s, %s", hdr.ds_version,
        hdr.dsc_hash != NULL ? "a program loaded" : "no program loaded");
}

/* Every handler harness.ds's rules reach was seen to run, and the
   division that traps wrote nothing: a run in which a rule silently did
   not fire must not end "harness: OK". */
static void check_reached(const harness_state *h) {
    bool ok = true;
    size_t i;
    SEC("reached");
    for (i = 0; i < N_RULE_LOGS; i++) {
        if (!h->rule_logged[i]) {
            fprintf(stderr, "FAILED: no log line opening \"%s\"\n",
                    rule_logs[i]);
            ok = false;
        }
    }
    if (h->trapped_logged) {
        fprintf(stderr, "FAILED: the trapped division logged\n");
        ok = false;
    }
    /* `pinged` calls svc.echo and svc.absent; `pinged` writes the entry
       and `forgot` deletes it. */
    if (h->calls != 2 || h->cache_sets != 1 || h->cache_deletes != 1) {
        fprintf(stderr, "FAILED: %u calls, %u cache writes, %u cache "
                "deletes; want 2, 1 and 1\n", h->calls, h->cache_sets,
                h->cache_deletes);
        ok = false;
    }
    if (!ok) {
        exit(EXIT_FAILURE);
    }
    LOG("%u log lines, %u calls, %u cache writes, %u cache deletes",
        h->logs, h->calls, h->cache_sets, h->cache_deletes);
}

/* Demo found again by id and retracted; after that its id finds nothing,
   which is how a holder of an id learns the fact is gone. Then the halt
   latch, unset on a run that raised no EngineError, and the engine
   freed. */
static void teardown(ds_engine_t *e, uint64_t demo_id) {
    ds_fact_t *fact = NULL;
    bool halted = true;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    SEC("teardown");
    must("fact_find Demo", ds_engine_fact_find(e, demo_id, &fact));
    must("retract Demo", ds_engine_retract(e, fact));
    expect("fact_find Demo (retracted)",
           ds_engine_fact_find(e, demo_id, &fact), DS_ERR_NOT_FOUND,
           "the fact has gone, and an id is never reassigned");
    must("ds_engine_halted", ds_engine_halted(e, &halted, &fault));
    if (halted) {
        fprintf(stderr, "FAILED: the engine halted, fault %d\n",
                (int) fault);
        exit(EXIT_FAILURE);
    }
    must("ds_engine_free", ds_engine_free(e));
}

/* ------------------------------------------------------------------ */
/*  main                                                              */
/* ------------------------------------------------------------------ */

/* One argument: the .dsc file dsc compiled from harness.ds. */
int main(int argc, char **argv) {
    static harness_state h;     /* zeroed: nothing reached, nothing owed */
    ds_engine_t *e;
    fact_ids ids;

    if (argc != 2) {
        fprintf(stderr, "usage: %s harness.dsc\n",
                argc > 0 ? argv[0] : "harness");
        return EXIT_FAILURE;
    }
    e = make_engine();
    register_callbacks(e, &h);
    setup_clock(e, &h);
    capabilities(e);
    capacity(e);
    load_program(e, argv[1]);
    program_metadata(e);
    program_services(e);
    seed_cache(e);
    inspect_schemas(e);
    ids = assert_facts(e);
    read_facts(e, ids.demo);
    fact_metadata(e, &ids);
    json_utilities();
    run_program(e);
    answer_calls(e, &h);
    forward_fact(e, &h);
    read_series(e);
    forget(e);
    pump_and_ttl(e, &h);
    introspection(e);
    determinism_reads(e);
    check_reached(&h);
    teardown(e, ids.demo);

    printf("\nharness: OK\n");
    return EXIT_SUCCESS;
}

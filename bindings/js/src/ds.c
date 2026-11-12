/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * @ds-lang/ds — the JavaScript binding to libds. The C glue, written to Node-API.
 * Its design is bindings/JS_BINDING.md.
 *
 * ONE GLUE, TWO TARGETS. This file is compiled unchanged by the row's `cc` into
 * a `.node`, and by `emcc` against emnapi into wasm (JS_BINDING.md §1; the two
 * were measured to give identical transcripts). There is no `#ifdef` for either
 * target here, and there must not be: the moment one appears, the targets have
 * two glues.
 *
 * WHAT IT DOES AND WHAT IT LEAVES TO lib/index.js. This layer converts values
 * and owns every pointer. The ES module owns names, argument shapes and the
 * public classes. Nothing here names a status code: a failing libds call
 * becomes a `DsError(status, detail)` built from libds's own numbers, with
 * `detail` copied at once because libds lends it only until the next call.
 *
 * FACT HANDLES ARE FENCED. libds has no lookup by fact id, so a handle is a
 * pointer — and the engine retracts facts on its own (upsert, TTL sweep, truth
 * maintenance) and may reuse the storage. So the glue owns the engine's stream
 * callback and, in C, marks a handle dead the moment its FACT_RETRACT passes.
 * A dead handle is refused with DS_ERR_FACT_INVALID rather than dereferenced.
 * The marking is C and runs whether or not a JS stream callback is set. It runs
 * AFTER the JS callback, so a retracted fact's handle is readable during its own
 * FACT_RETRACT event and dead from the moment the callback returns.
 *
 * A CALLBACK THAT THROWS HAS FAILED, and libds hears DS_ERR_ACTION_FAILED,
 * because libds acts on it: a failed call or cache write-through
 * surfaces from pump ([NCBK.1.5]). Where the exception goes depends on the
 * callback (JS_BINDING.md §3.5):
 * - the handlers (the cache pair) are lib/bind.js's to report: it keeps the
 *   exception for the DsError of the call that ran them, or reports it as
 *   uncaught, so the glue clears it;
 * - the call callback's goes to the unraisable hook lib/bind.js registers,
 *   printed to stderr unless replaced, and the pump that ran it does the rest
 *   of its work before it returns that failure;
 * - the stream callback is an observer and answers DS_OK: a listener's throw is
 *   the platform's to report.
 * A callback's return value is ignored.
 *
 * THE GLUE HOLDS CALLBACKS WEAKLY. lib/index.js keeps each one on its Engine;
 * the glue keeps a zero-count reference. A strong one would be a GC root, and a
 * callback that closes over its own Engine would then keep the engine alive
 * forever — pyds breaks that cycle with tp_traverse, which Node-API has no
 * counterpart for. JS runs only inside a call from JS: never from a finaliser,
 * and never while the engine is being freed.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAPI_VERSION 8
#include <node_api.h>

#include "libds.h"
#include "rfcs/rfcs.h"  /* the C recorder and replayer; the tarball ships it */
#include "ds_names.h"   /* the enum names @ds-lang/ds shares with pyds */

/* ── state ──────────────────────────────────────────────────────────────── */

typedef struct js_engine js_engine_t;

/* The JS callback slots. The names are what setCallback takes and what the
   unraisable hook is told. There is no time-zone resolver: zones resolve
   through `TimeZoneOffset` facts, which a host asserts ([LTIM.10.7]).
   No `sample` and no `seriesDeclared`: there is no samples plane. */
enum {
    CB_STREAM, CB_CALL, CB_LOG, CB_METRIC,
    CB_CACHE_SET, CB_CACHE_DELETE, CB_N
};
static const char *const CB_NAMES[CB_N] = {
    "stream", "call", "log", "metric",
    "cacheSet", "cacheDelete",
};

/* One per fact the JS side holds a handle to. `eng` is non-NULL exactly while
   the fact is in the engine's live-handle table; `js_refs` counts the JS
   wrappers. Freed when both have let go. */
typedef struct js_fact {
    ds_fact_t     *fact;
    uint64_t       id;
    js_engine_t *eng;
    uint32_t       js_refs;
    bool           in_wm;   /* after_replay's mark, false between its walks */
} js_fact_t;

struct js_engine {
    ds_engine_t  *e;
    /* ds_fact_t* -> js_fact_t*, open addressing, linear probing. */
    js_fact_t **tab;
    size_t        cap, used, tomb;
    /* Callbacks: weak references (see the header), and the env they are called
       in. `closing` is set before teardown so no JS runs during it. */
    napi_env      env;
    napi_ref      cb[CB_N];
    bool          closing;
    uint32_t      in_callback;  /* JS callbacks running now; close() waits for 0 */
    /* recordTo: the C recorder, chained in on_stream ahead of the JS
       stream callback (RECTEE1's order). The sink is a JS function, held
       weakly like the callbacks; the first error it throws is kept strongly
       for stopRecording to hand back as `cause`. */
    bool                recording;
    ds_rfcs_recorder_t  rec;
    uint8_t            *recbuf;
    napi_ref            rec_sink;
    napi_ref            rec_err;
    /* replayBegin: the one open chunked replay, if any. Its compare recorder
       has the stream slot while it is open, so the fence is off, and a handle
       is refused rather than read (arg_fact). */
    struct js_replay *replay;
    /* A replay halted the engine, so after_replay could neither restore the
       stream hook nor walk working memory: a handle may name a freed fact. */
    bool          replay_halted;
    /* Each schema's slot names and which are Json, as the last load left
       them (`snap_take`). Read only when the engine has halted, to judge a
       Json slot's text before the halt ([LSTR.8.5]); see `f_assert`. */
    struct js_schema_snap *snap;
    size_t        n_snap;
};

/* One schema's shape, copied out of libds while the engine can be read. A
   halted engine refuses every schema read ([NCBK.2.9]), and the glue needs
   to know which slot is Json to judge its text first ([LSTR.8.5]). The
   program a load fixes does not change after it, so the copy is the
   program's. */
typedef struct js_schema_snap {
    char     *name;
    uint32_t  n;
    char    **slot;
    bool     *json;
} js_schema_snap_t;

/* One chunked replay (ds_rfcs_replay_begin/feed/finish). Owned by its JS
   external; `je` is cleared when the engine closes first. */
typedef struct js_replay {
    ds_rfcs_replay_ctx_t *ctx;
    js_engine_t        *je;
} js_replay_t;

#define DS_JS_RECBUF (64u * 1024u)   /* the largest single atom, as pyds's PYDS_RECBUF */

#define TOMB ((js_fact_t *) (uintptr_t) 1)

typedef struct {
    napi_ref error_ctor;        /* DsError, handed over by lib/index.js */
    napi_ref unraisable;        /* (error, where) -> void, likewise */
} js_instance_t;

/* ── errors ─────────────────────────────────────────────────────────────── */

static napi_value make_ds_error(napi_env env, int32_t status, const char *detail) {
    js_instance_t *inst = NULL;
    napi_value ctor = NULL, args[2], err = NULL;
    napi_get_instance_data(env, (void **) &inst);
    napi_create_int32(env, status, &args[0]);
    /* Copied here: libds lends `detail` only until its next call. */
    napi_create_string_utf8(env, detail ? detail : "", NAPI_AUTO_LENGTH, &args[1]);
    if (inst != NULL && inst->error_ctor != NULL
        && napi_get_reference_value(env, inst->error_ctor, &ctor) == napi_ok
        && ctor != NULL
        && napi_new_instance(env, ctor, 2, args, &err) == napi_ok)
        return err;
    /* Before init(): a plain Error carrying the same two fields. */
    napi_value msg;
    napi_create_string_utf8(env, "ds status (DsError not registered)", NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, NULL, msg, &err);
    napi_set_named_property(env, err, "status", args[0]);
    napi_set_named_property(env, err, "detail", args[1]);
    return err;
}

static napi_value throw_ds(napi_env env, ds_result_t r) {
    napi_throw(env, make_ds_error(env, r.status, r.detail));
    return NULL;
}

static napi_value throw_status(napi_env env, int32_t status, const char *detail) {
    napi_throw(env, make_ds_error(env, status, detail));
    return NULL;
}

static napi_value throw_type(napi_env env, const char *msg) {
    napi_throw_type_error(env, NULL, msg);
    return NULL;
}

/* Every call into libds ends here. A pending JS exception wins over libds's
   result. No callback leaves one pending: each callback's exception has been
   reported or cleared by the time libds returns (cb_end). */
static napi_value finish(napi_env env, ds_result_t r, napi_value ok) {
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (pending)
        return NULL;
    if (r.status != DS_OK)
        return throw_ds(env, r);
    if (ok == NULL)
        napi_get_undefined(env, &ok);
    return ok;
}

/* ── the live-handle table ──────────────────────────────────────────────── */

static size_t ptr_hash(const void *p, size_t cap) {
    uint64_t x = (uint64_t) (uintptr_t) p;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (size_t) (x & (cap - 1));
}

static js_fact_t **tab_slot(js_engine_t *je, const ds_fact_t *f, bool for_insert) {
    if (je->cap == 0)
        return NULL;
    size_t i = ptr_hash(f, je->cap);
    js_fact_t **first_tomb = NULL;
    for (size_t n = 0; n < je->cap; n++, i = (i + 1) & (je->cap - 1)) {
        js_fact_t *s = je->tab[i];
        if (s == NULL)
            return for_insert ? (first_tomb ? first_tomb : &je->tab[i]) : NULL;
        if (s == TOMB) {
            if (first_tomb == NULL)
                first_tomb = &je->tab[i];
            continue;
        }
        if (s->fact == f)
            return &je->tab[i];
    }
    return for_insert ? first_tomb : NULL;
}

static bool tab_grow(js_engine_t *je) {
    size_t ncap = je->cap ? je->cap * 2 : 64;
    js_fact_t **old = je->tab;
    size_t ocap = je->cap;
    je->tab = calloc(ncap, sizeof *je->tab);
    if (je->tab == NULL) {
        je->tab = old;
        return false;
    }
    je->cap = ncap;
    je->used = 0;
    je->tomb = 0;
    for (size_t i = 0; i < ocap; i++)
        if (old[i] != NULL && old[i] != TOMB) {
            *tab_slot(je, old[i]->fact, true) = old[i];
            je->used++;
        }
    free(old);
    return true;
}

static js_fact_t *tab_find(js_engine_t *je, const ds_fact_t *f) {
    js_fact_t **s = tab_slot(je, f, false);
    return s ? *s : NULL;
}

static bool tab_insert(js_engine_t *je, js_fact_t *jf) {
    if ((je->used + je->tomb + 1) * 4 >= je->cap * 3 && !tab_grow(je))
        return false;
    js_fact_t **s = tab_slot(je, jf->fact, true);
    if (*s == TOMB)
        je->tomb--;
    *s = jf;
    je->used++;
    return true;
}

static void release_slot(js_engine_t *je, js_fact_t **s) {
    js_fact_t *jf = *s;
    *s = TOMB;
    je->used--;
    je->tomb++;
    jf->eng = NULL;
    jf->fact = NULL;
    if (jf->js_refs == 0)
        free(jf);
}

/* The fact left working memory: the handle is dead from here on. */
static void release_fact(js_engine_t *je, const ds_fact_t *f) {
    js_fact_t **s = tab_slot(je, f, false);
    if (s != NULL)
        release_slot(je, s);
}

/* ── engine lifetime ────────────────────────────────────────────────────── */

/* pyds's pyds_engine_drop_callbacks: unregister every JS-facing trampoline
   libds-side, then drop the references. The stream hook stays — it is the
   handle fence, and with `closing` set it no longer enters JS. */
static void drop_callbacks(napi_env env, js_engine_t *je) {
    je->closing = true;
    if (je->e != NULL) {
        ds_engine_set_call_callback(je->e, NULL, NULL);
        ds_engine_set_log_callback(je->e, NULL, NULL);
        ds_engine_set_metric_callback(je->e, NULL, NULL);
        ds_engine_cache_callbacks(je->e, DS_CACHE_CB_ABI_VERSION, NULL, NULL, NULL);
    }
    for (int i = 0; i < CB_N; i++)
        if (je->cb[i] != NULL) {
            napi_delete_reference(env, je->cb[i]);
            je->cb[i] = NULL;
        }
}

/* Detach the recorder and release what it held. Teardown has no way to report
   the recorder's error; stopRecording is the checked path, as in pyds. */
static void recording_release(napi_env env, js_engine_t *je) {
    je->recording = false;
    free(je->recbuf);
    je->recbuf = NULL;
    memset(&je->rec, 0, sizeof je->rec);
    if (je->rec_sink != NULL)
        napi_delete_reference(env, je->rec_sink);
    if (je->rec_err != NULL)
        napi_delete_reference(env, je->rec_err);
    je->rec_sink = je->rec_err = NULL;
}

static void snap_free(js_engine_t *je) {
    for (size_t i = 0; i < je->n_snap; i++) {
        js_schema_snap_t *s = &je->snap[i];
        for (uint32_t j = 0; s->slot != NULL && j < s->n; j++)
            free(s->slot[j]);
        free(s->slot);
        free(s->json);
        free(s->name);
    }
    free(je->snap);
    je->snap = NULL;
    je->n_snap = 0;
}

/* A heap copy of `s`, or NULL when out of memory. */
static char *dup_str(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p != NULL)
        memcpy(p, s, n);
    return p;
}

/* Copy every schema's slot names and Json-ness out of a readable engine. A
   copy that cannot be made is no copy: `f_assert` then answers a halted
   engine's assert with the halt, as it did before the copy existed. */
static void snap_take(js_engine_t *je) {
    snap_free(je);
    size_t n = 0;
    if (ds_engine_schema_count(je->e, &n).status != DS_OK || n == 0)
        return;
    js_schema_snap_t *snap = calloc(n, sizeof *snap);
    if (snap == NULL)
        return;
    je->snap = snap;
    je->n_snap = n;
    for (size_t i = 0; i < n; i++) {
        const ds_schema_t *schema = NULL;
        const char *name = NULL;
        uint32_t slots = 0;
        if (ds_engine_schema_at(je->e, i, &schema).status != DS_OK
            || ds_schema_get_name(schema, &name).status != DS_OK
            || ds_schema_get_slot_count(schema, &slots).status != DS_OK
            || (snap[i].name = dup_str(name)) == NULL
            || (snap[i].slot = calloc(slots ? slots : 1, sizeof *snap[i].slot)) == NULL
            || (snap[i].json = calloc(slots ? slots : 1, sizeof *snap[i].json)) == NULL) {
            snap_free(je);
            return;
        }
        snap[i].n = slots;
        for (uint32_t j = 0; j < slots; j++) {
            ds_slot_desc_t d;
            if (ds_schema_get_slot(schema, j, &d).status != DS_OK
                || (snap[i].slot[j] = dup_str(d.name)) == NULL) {
                snap_free(je);
                return;
            }
            snap[i].json[j] = d.type == DS_SLOT_TYPE_JSON;
        }
    }
}

static void engine_close(napi_env env, js_engine_t *je) {
    snap_free(je);
    if (je->e == NULL)
        return;
    recording_release(env, je);
    if (je->replay != NULL) {       /* the ctx refers to the engine: finish it now */
        ds_rfcs_replay_finish(je->replay->ctx, NULL);
        je->replay->ctx = NULL;
        je->replay->je = NULL;
        je->replay = NULL;
    }
    drop_callbacks(env, je);
    ds_engine_free(je->e);          /* the stream hook may still run: C only now */
    je->e = NULL;
    for (size_t i = 0; i < je->cap; i++) {
        js_fact_t *jf = je->tab[i];
        if (jf == NULL || jf == TOMB)
            continue;
        jf->eng = NULL;
        jf->fact = NULL;
        if (jf->js_refs == 0)
            free(jf);
    }
    free(je->tab);
    je->tab = NULL;
    je->cap = je->used = je->tomb = 0;
}

static void engine_finalize(napi_env env, void *data, void *hint) {
    (void) hint;
    js_engine_t *je = data;
    engine_close(env, je);          /* safe: `closing` keeps JS out of it */
    free(je);
}

static void fact_finalize(napi_env env, void *data, void *hint) {
    (void) env;
    (void) hint;
    js_fact_t *jf = data;
    if (jf->js_refs > 0)
        jf->js_refs--;
    if (jf->js_refs == 0 && jf->eng == NULL)
        free(jf);
}

/* ── argument helpers ───────────────────────────────────────────────────── */

static js_engine_t *arg_engine(napi_env env, napi_value v) {
    void *p = NULL;
    if (napi_get_value_external(env, v, &p) != napi_ok || p == NULL) {
        throw_type(env, "not an engine handle");
        return NULL;
    }
    js_engine_t *je = p;
    if (je->e == NULL) {
        throw_status(env, DS_ERR_STATE, "the engine is closed");
        return NULL;
    }
    return je;
}

/* A live fact of THIS engine, or a thrown error. */
static js_fact_t *arg_fact(napi_env env, napi_value v, js_engine_t *je) {
    void *p = NULL;
    if (napi_get_value_external(env, v, &p) != napi_ok || p == NULL) {
        throw_type(env, "not a fact handle");
        return NULL;
    }
    js_fact_t *jf = p;
    if (jf->eng == NULL) {
        throw_status(env, DS_ERR_FACT_INVALID,
                     "the fact has left working memory (retracted, replaced or expired)");
        return NULL;
    }
    /* Neither case reaches the fact: it may have been freed unannounced. */
    if (jf->eng->replay != NULL) {
        throw_status(env, DS_ERR_STATE, "a replay is open on this fact's engine");
        return NULL;
    }
    if (jf->eng->replay_halted) {
        throw_status(env, DS_ERR_ENGINE_HALTED, "a replay halted this fact's engine");
        return NULL;
    }
    if (je != NULL && jf->eng != je) {
        throw_status(env, DS_ERR_FACT_INVALID, "the fact belongs to another engine");
        return NULL;
    }
    return jf;
}

static napi_value wrap_fact(napi_env env, js_engine_t *je, ds_fact_t *f) {
    napi_value ext;
    js_fact_t *jf = tab_find(je, f);
    if (jf == NULL) {
        jf = calloc(1, sizeof *jf);
        if (jf == NULL)
            return throw_status(env, DS_ERR_OOM, "fact handle");
        jf->fact = f;
        jf->eng = je;
        ds_fact_get_id(f, &jf->id);
        if (!tab_insert(je, jf)) {
            free(jf);
            return throw_status(env, DS_ERR_OOM, "fact handle table");
        }
    }
    jf->js_refs++;
    if (napi_create_external(env, jf, fact_finalize, NULL, &ext) != napi_ok) {
        jf->js_refs--;
        return NULL;
    }
    return ext;
}

/* A non-negative 64-bit quantity (ns): a BigInt, or a safe integer Number. */
static bool get_u64(napi_env env, napi_value v, uint64_t *out, const char *what) {
    napi_valuetype t;
    napi_typeof(env, v, &t);
    char msg[128];
    if (t == napi_bigint) {
        bool lossless = false;
        napi_get_value_bigint_uint64(env, v, out, &lossless);
        if (lossless)
            return true;
        snprintf(msg, sizeof msg, "%s: BigInt outside 0..2^64-1", what);
    } else if (t == napi_number) {
        double d = 0;
        napi_get_value_double(env, v, &d);
        if (isfinite(d) && d == trunc(d) && d >= 0 && d <= 9007199254740991.0) {
            *out = (uint64_t) d;
            return true;
        }
        snprintf(msg, sizeof msg, "%s: not a safe non-negative integer Number; pass a BigInt", what);
    } else {
        snprintf(msg, sizeof msg, "%s: want a BigInt or a safe integer Number", what);
    }
    napi_throw_type_error(env, NULL, msg);
    return false;
}

/* A signed 64-bit quantity (an instant in ns, which may be before the epoch):
   a BigInt, or a safe integer Number. */
static bool get_i64(napi_env env, napi_value v, int64_t *out, const char *what) {
    napi_valuetype t;
    napi_typeof(env, v, &t);
    char msg[128];
    if (t == napi_bigint) {
        bool lossless = false;
        napi_get_value_bigint_int64(env, v, out, &lossless);
        if (lossless)
            return true;
        snprintf(msg, sizeof msg, "%s: BigInt outside -2^63..2^63-1", what);
    } else if (t == napi_number) {
        double d = 0;
        napi_get_value_double(env, v, &d);
        if (isfinite(d) && d == trunc(d) && fabs(d) <= 9007199254740991.0) {
            *out = (int64_t) d;
            return true;
        }
        snprintf(msg, sizeof msg, "%s: not a safe integer Number; pass a BigInt", what);
    } else {
        snprintf(msg, sizeof msg, "%s: want a BigInt or a safe integer Number", what);
    }
    napi_throw_type_error(env, NULL, msg);
    return false;
}

/* The code point at u[*i], advancing *i past it: a surrogate pair is one code
   point, and a lone surrogate (half of no pair) is itself. */
static uint32_t next_code_point(const char16_t *u, size_t n, size_t *i) {
    uint32_t c = u[(*i)++];
    if (c >= 0xD800u && c <= 0xDBFFu && *i < n && u[*i] >= 0xDC00u && u[*i] <= 0xDFFFu)
        c = 0x10000u + ((c - 0xD800u) << 10) + (uint32_t) (u[(*i)++] - 0xDC00u);
    return c;
}

/* The string's text, NUL-terminated, with its byte length in `*len`: each
   code point in UTF-8's form for it, a lone surrogate included, as the three
   octets ED A0 80..ED BF BF that no well-formed UTF-8 holds. `*lone` says
   whether there was one. A JS string may hold U+0000, so strlen can be
   shorter than `*len`.

   Not napi_get_value_string_utf8, which writes U+FFFD for a lone surrogate:
   the repair [LSTR.8.5] forbids, made before anything can refuse.
   Carried as its own octets, the text reaches libds ill-formed, and libds
   refuses it with DS_ERR_ENCODING where [LSTR.8.5] checks, in the order of
   [NFCT.2.11] and [NLFC.9.6]. A name that is looked up (a schema, a rule, a
   callback) matches nothing, since no name holds a surrogate, and takes that
   name's own refusal. Text that nothing checks and something keeps (the
   engine's identity, an announced slot's name) is refused by its caller,
   on `*lone`.

   NULL for a value that is not a string, with nothing pending, so the caller
   says what it wanted; and for a failed allocation, with DS_ERR_OOM pending,
   which the caller's own throw then does not replace. */
static char *get_text(napi_env env, napi_value v, size_t *len, bool *lone) {
    size_t n16 = 0;
    *lone = false;
    if (napi_get_value_string_utf16(env, v, NULL, 0, &n16) != napi_ok)
        return NULL;
    char16_t *u = malloc((n16 + 1) * sizeof *u);
    if (u == NULL) {
        throw_status(env, DS_ERR_OOM, "text");
        return NULL;
    }
    napi_get_value_string_utf16(env, v, u, n16 + 1, &n16);
    size_t n = 0;
    for (size_t i = 0; i < n16;) {
        uint32_t c = next_code_point(u, n16, &i);
        n += c < 0x80u ? 1 : c < 0x800u ? 2 : c < 0x10000u ? 3 : 4;
    }
    char *s = malloc(n + 1);
    if (s == NULL) {
        free(u);
        throw_status(env, DS_ERR_OOM, "text");
        return NULL;
    }
    unsigned char *p = (unsigned char *) s;
    for (size_t i = 0; i < n16;) {
        uint32_t c = next_code_point(u, n16, &i);
        if (c >= 0xD800u && c <= 0xDFFFu)
            *lone = true;
        if (c < 0x80u) {
            *p++ = (unsigned char) c;
        } else if (c < 0x800u) {
            *p++ = (unsigned char) (0xC0u | (c >> 6));
            *p++ = (unsigned char) (0x80u | (c & 0x3Fu));
        } else if (c < 0x10000u) {
            *p++ = (unsigned char) (0xE0u | (c >> 12));
            *p++ = (unsigned char) (0x80u | ((c >> 6) & 0x3Fu));
            *p++ = (unsigned char) (0x80u | (c & 0x3Fu));
        } else {
            *p++ = (unsigned char) (0xF0u | (c >> 18));
            *p++ = (unsigned char) (0x80u | ((c >> 12) & 0x3Fu));
            *p++ = (unsigned char) (0x80u | ((c >> 6) & 0x3Fu));
            *p++ = (unsigned char) (0x80u | (c & 0x3Fu));
        }
    }
    *p = '\0';
    free(u);
    *len = n;
    return s;
}

static char *get_string_len(napi_env env, napi_value v, size_t *len) {
    bool lone = false;
    return get_text(env, v, len, &lone);
}

/* A name libds looks up as a C string (a schema, a rule, a callback, a cache
   key, a clock mode). U+0000 would cut it short, so "Reading\0x" would find
   Reading: refused with a TypeError, as an engine identity is (opt_id_arg), and
   pyds refuses it too. NULL for a value that is not a string, or with an
   exception pending, which a caller's own throw then does not replace. */
static char *get_string(napi_env env, napi_value v) {
    size_t n = 0;
    char *s = get_string_len(env, v, &n);
    if (s != NULL && strlen(s) != n) {
        free(s);
        napi_throw_type_error(env, NULL, "a name holding U+0000");
        return NULL;
    }
    return s;
}

/* ── values: libds -> JS ────────────────────────────────────────────────── */

static napi_value slot_to_js(napi_env env, js_engine_t *je, const ds_slot_value_t *v) {
    napi_value out = NULL;
    switch (v->kind) {
    case DS_SLOT_INT:
        napi_create_bigint_int64(env, v->v.i, &out);
        break;
    case DS_SLOT_FLOAT:
        napi_create_double(env, v->v.f, &out);
        break;
    case DS_SLOT_STRING:
        napi_create_string_utf8(env, v->v.s, NAPI_AUTO_LENGTH, &out);
        break;
    case DS_SLOT_BOOL:
        napi_get_boolean(env, v->v.b, &out);
        break;
    case DS_SLOT_NULL:
        napi_get_null(env, &out);
        break;
    case DS_SLOT_BYTES: {
        /* napi_create_buffer_copy, NOT napi_create_arraybuffer + memcpy. The
           latter writes through the data pointer, and under emnapi that
           pointer is wasm memory the JS ArrayBuffer does not see: the bytes
           read back as zeros (found by the wasm lane). The copy call hands the
           source to the runtime, which copies it into the JS side on both
           targets. lib/index.js turns the Buffer into a plain Uint8Array. */
        static const uint8_t empty[1] = { 0 };
        const void *src = v->v.bytes.len ? (const void *) v->v.bytes.data
                                         : (const void *) empty;
        napi_create_buffer_copy(env, v->v.bytes.len, src, NULL, &out);
        break;
    }
    case DS_SLOT_JSON: {
        /* Canonical text from libds's own serialiser — no second canonical
           form in JS, and no JSON.parse rounding a large integer. */
        char *text = NULL;
        size_t n = 0;
        ds_result_t r = ds_json_serialize(v->v.json, &text, &n);
        if (r.status != DS_OK)
            return throw_ds(env, r);
        napi_create_string_utf8(env, text, n, &out);
        ds_free(text);              /* libds's buffer: its free (IALC.4.2) */
        break;
    }
    case DS_SLOT_FACT_REF:
        /* NULL once the referenced fact has left working memory: libds
           resolves the slot on read. */
        if (v->v.ref == NULL)
            napi_get_null(env, &out);
        else
            out = wrap_fact(env, je, v->v.ref);
        break;
    default:
        napi_get_undefined(env, &out);
    }
    return out;
}

static bool json_to_js(napi_env env, const ds_json_t *t, napi_value *out);

/* Bytes as a Buffer, copied by the runtime (see slot_to_js's Bytes case for
   why not an ArrayBuffer and a memcpy). lib/bind.js makes it a Uint8Array. */
static napi_value bytes_to_js(napi_env env, const uint8_t *data, size_t len) {
    static const uint8_t empty[1] = { 0 };
    napi_value out = NULL;
    napi_create_buffer_copy(env, len, len && data ? (const void *) data : (const void *) empty, NULL,
                            &out);
    return out;
}

/* One typed call argument, as slot_to_js gives a slot of its kind: an
   Int as a BigInt, Bytes as a Buffer. Json is `{ json }`, its canonical text,
   which lib/bind.js makes a JsonText: a call argument has no schema beside it
   to say a string is a document, so the value carries its kind. A
   fact passed as an argument is not live in this engine, so it is no Fact but
   `{ schema, assertedAt, external }`: its schema, the UTC instant it entered
   working memory (ns, BigInt, or null when the wall clock had no value then,
   RFCS.23.5), and its FactExternal bytes. */
static napi_value arg_to_js(napi_env env, const ds_arg_value_t *v) {
    napi_value out = NULL;
    switch (v->kind) {
    case DS_ARG_INT:
        napi_create_bigint_int64(env, v->v.i, &out);
        break;
    case DS_ARG_FLOAT:
        napi_create_double(env, v->v.f, &out);
        break;
    case DS_ARG_STRING:
        napi_create_string_utf8(env, v->v.s ? v->v.s : "", NAPI_AUTO_LENGTH, &out);
        break;
    case DS_ARG_BOOL:
        napi_get_boolean(env, v->v.b, &out);
        break;
    case DS_ARG_NULL:
        napi_get_null(env, &out);
        break;
    case DS_ARG_BYTES:
        out = bytes_to_js(env, v->v.bytes.data, v->v.bytes.len);
        break;
    case DS_ARG_JSON: {
        napi_value text;
        if (!json_to_js(env, v->v.json, &text))
            return NULL;
        if (v->v.json == NULL) {        /* no tree: json_to_js gave null */
            out = text;
            break;
        }
        napi_create_object(env, &out);
        napi_set_named_property(env, out, "json", text);
        break;
    }
    case DS_ARG_ENCODED_FACT: {
        napi_value tmp;
        napi_create_object(env, &out);
        napi_create_string_utf8(env, v->v.fact.schema ? v->v.fact.schema : "", NAPI_AUTO_LENGTH, &tmp);
        napi_set_named_property(env, out, "schema", tmp);
        if (v->v.fact.asserted_at_set)
            napi_create_bigint_int64(env, v->v.fact.asserted_at, &tmp);
        else
            napi_get_null(env, &tmp);
        napi_set_named_property(env, out, "assertedAt", tmp);
        napi_set_named_property(env, out, "external",
                                bytes_to_js(env, v->v.fact.bytes.data, v->v.fact.bytes.len));
        break;
    }
    default:
        napi_get_undefined(env, &out);
    }
    return out;
}

/* A call's arguments as an object, kwarg name -> value. NULL, with an
   exception pending, if a Json argument could not be serialised. */
static napi_value args_to_js(napi_env env, const ds_arg_t *args, uint32_t n) {
    napi_value o;
    napi_create_object(env, &o);
    for (uint32_t i = 0; args != NULL && i < n; i++) {
        napi_value v = arg_to_js(env, &args[i].value);
        if (v == NULL)
            return NULL;
        napi_set_named_property(env, o, args[i].name ? args[i].name : "", v);
    }
    return o;
}

static napi_value fact_to_js(napi_env env, js_engine_t *je, const ds_fact_t *f) {
    napi_value obj, slots, tmp;
    const ds_schema_t *s = NULL;
    const char *sname = NULL;
    uint64_t id = 0;
    uint32_t n = 0;

    ds_fact_get_schema(f, &s);
    ds_schema_get_name(s, &sname);
    ds_fact_get_id(f, &id);
    ds_fact_get_slot_count(f, &n);

    napi_create_object(env, &obj);
    napi_create_string_utf8(env, sname ? sname : "", NAPI_AUTO_LENGTH, &tmp);
    napi_set_named_property(env, obj, "schema", tmp);
    napi_create_bigint_uint64(env, id, &tmp);
    napi_set_named_property(env, obj, "id", tmp);
    napi_create_object(env, &slots);
    for (uint32_t i = 0; i < n; i++) {
        const char *name = NULL;
        ds_slot_value_t val;
        ds_result_t r = ds_fact_get_slot(f, i, &name, &val);
        if (r.status != DS_OK)
            return throw_ds(env, r);
        napi_value jv = slot_to_js(env, je, &val);
        if (jv == NULL)
            return NULL;
        napi_set_named_property(env, slots, name, jv);
    }
    napi_set_named_property(env, obj, "slots", slots);
    return obj;
}

static const char *slot_type_name(const ds_slot_desc_t *d) {
    switch (d->type) {
    case DS_SLOT_TYPE_INT:      return "Int";
    case DS_SLOT_TYPE_FLOAT:    return "Float";
    case DS_SLOT_TYPE_STRING:   return "String";
    case DS_SLOT_TYPE_BOOL:     return "Bool";
    case DS_SLOT_TYPE_JSON:     return "Json";
    case DS_SLOT_TYPE_BYTES:    return "Bytes";
    case DS_SLOT_TYPE_TIME:     return "Time";
    case DS_SLOT_TYPE_DATE:     return "Date";
    case DS_SLOT_TYPE_DURATION: return "Duration";
    case DS_SLOT_TYPE_SCHEMA: {
        const char *n = NULL;
        if (d->schema_ref != NULL)
            ds_schema_get_name(d->schema_ref, &n);
        return n ? n : "";
    }
    default:                    return "";
    }
}

/* "internal" is the built-in fault schemas, ComputationError and TypeError
   ([NDBG.2.2], [LSCP.2.6.2]): a host tells them from its own schemas by
   this, never by name. */
static const char *lifecycle_name(ds_schema_lifecycle_t lc) {
    switch (lc) {
    case DS_SCHEMA_LIFECYCLE_LOGICAL:  return "logical";
    case DS_SCHEMA_LIFECYCLE_TTL:      return "ttl";
    case DS_SCHEMA_LIFECYCLE_INTERNAL: return "internal";
    default:                           return "";
    }
}

static napi_value schema_to_js(napi_env env, const ds_schema_t *s) {
    napi_value obj, tmp, arr;
    const char *name = NULL;
    ds_schema_lifecycle_t lc = DS_SCHEMA_LIFECYCLE_LOGICAL;
    uint64_t ttl = 0;
    uint32_t n = 0;
    ds_result_t r;

    if ((r = ds_schema_get_name(s, &name)).status != DS_OK
        || (r = ds_schema_get_lifecycle(s, &lc)).status != DS_OK
        || (r = ds_schema_get_ttl_ns(s, &ttl)).status != DS_OK
        || (r = ds_schema_get_slot_count(s, &n)).status != DS_OK)
        return throw_ds(env, r);

    napi_create_object(env, &obj);
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &tmp);
    napi_set_named_property(env, obj, "name", tmp);
    napi_create_string_utf8(env, lifecycle_name(lc), NAPI_AUTO_LENGTH, &tmp);
    napi_set_named_property(env, obj, "lifecycle", tmp);
    napi_create_bigint_uint64(env, ttl, &tmp);
    napi_set_named_property(env, obj, "ttlNs", tmp);
    napi_create_array_with_length(env, n, &arr);
    for (uint32_t i = 0; i < n; i++) {
        ds_slot_desc_t d;
        napi_value so;
        if ((r = ds_schema_get_slot(s, i, &d)).status != DS_OK)
            return throw_ds(env, r);
        napi_create_object(env, &so);
        napi_create_string_utf8(env, d.name, NAPI_AUTO_LENGTH, &tmp);
        napi_set_named_property(env, so, "name", tmp);
        napi_create_string_utf8(env, slot_type_name(&d), NAPI_AUTO_LENGTH, &tmp);
        napi_set_named_property(env, so, "type", tmp);
        if (d.identity_role == DS_IDENTITY_KEY)
            napi_create_string_utf8(env, "key", NAPI_AUTO_LENGTH, &tmp);
        else if (d.identity_role == DS_IDENTITY_MUTABLE)
            napi_create_string_utf8(env, "mutable", NAPI_AUTO_LENGTH, &tmp);
        else if (d.identity_role == DS_IDENTITY_ENGINE)
            napi_create_string_utf8(env, "engine", NAPI_AUTO_LENGTH, &tmp);
        else
            napi_get_null(env, &tmp);
        napi_set_named_property(env, so, "identity", tmp);
        napi_get_boolean(env, d.nullable, &tmp);
        napi_set_named_property(env, so, "nullable", tmp);
        napi_set_element(env, arr, i, so);
    }
    napi_set_named_property(env, obj, "slots", arr);
    return obj;
}

/* ── values: JS -> libds ────────────────────────────────────────────────── */

/* What an assert allocated, released after libds has copied it. */
typedef struct {
    char      *str;
    ds_json_t *json;
} owned_t;

static bool js_to_slot(napi_env env, js_engine_t *je, napi_value v,
                       const ds_slot_desc_t *d, ds_slot_value_t *out, owned_t *own) {
    napi_valuetype vt;
    char msg[256];
    napi_typeof(env, v, &vt);
    if (vt == napi_null) {
        /* libds decides whether null is admissible here ([LNUL.3.4]). */
        out->kind = DS_SLOT_NULL;
        return true;
    }
    switch (d->type) {
    case DS_SLOT_TYPE_INT:
    /* The temporal types are Int-represented: the value is a DS_SLOT_INT and
       only the declared type differs (libds.h, ds_slot_type_t). */
    case DS_SLOT_TYPE_TIME:
    case DS_SLOT_TYPE_DATE:
    case DS_SLOT_TYPE_DURATION:
        out->kind = DS_SLOT_INT;
        if (vt == napi_bigint) {
            bool lossless = false;
            napi_get_value_bigint_int64(env, v, &out->v.i, &lossless);
            if (lossless)
                return true;
            snprintf(msg, sizeof msg, "slot `%s`: BigInt outside int64", d->name);
        } else if (vt == napi_number) {
            double x = 0;
            napi_get_value_double(env, v, &x);
            /* Number.isSafeInteger, exactly — never a rounding. */
            if (isfinite(x) && x == trunc(x) && fabs(x) <= 9007199254740991.0) {
                out->v.i = (int64_t) x;
                return true;
            }
            snprintf(msg, sizeof msg,
                     "slot `%s`: not a safe integer Number; pass a BigInt", d->name);
        } else {
            snprintf(msg, sizeof msg, "slot `%s` is %s: want a BigInt or a safe integer", d->name,
                     slot_type_name(d));
        }
        break;
    case DS_SLOT_TYPE_FLOAT:
        if (vt == napi_number) {
            out->kind = DS_SLOT_FLOAT;
            napi_get_value_double(env, v, &out->v.f);
            return true;
        }
        snprintf(msg, sizeof msg, "slot `%s` is Float: want a Number", d->name);
        break;
    case DS_SLOT_TYPE_STRING:
        if (vt == napi_string) {
            size_t n = 0;
            own->str = get_string_len(env, v, &n);
            if (own->str == NULL) {
                throw_status(env, DS_ERR_OOM, "string slot");
                return false;
            }
            /* A String holds no U+0000 (LSTR.1.1). libds takes a C string,
               which a NUL would cut short, so the refusal is here, before
               the call, with the status the host arm names (LSTR.1.5). */
            if (strlen(own->str) != n) {
                snprintf(msg, sizeof msg, "slot `%s`: a String holds no U+0000", d->name);
                throw_status(env, DS_ERR_INVAL, msg);
                return false;
            }
            out->kind = DS_SLOT_STRING;
            out->v.s = own->str;
            return true;
        }
        snprintf(msg, sizeof msg, "slot `%s` is String: want a string", d->name);
        break;
    case DS_SLOT_TYPE_BOOL:
        if (vt == napi_boolean) {
            out->kind = DS_SLOT_BOOL;
            napi_get_value_bool(env, v, &out->v.b);
            return true;
        }
        snprintf(msg, sizeof msg, "slot `%s` is Bool: want a boolean", d->name);
        break;
    case DS_SLOT_TYPE_JSON:
        if (vt == napi_string) {
            /* JSON TEXT in, parsed by libds, at its whole length: a raw
               U+0000 in it, or a \u0000 escape, makes the text malformed
               (LSTR.1.5), where strlen would have cut it short. */
            size_t n = 0;
            char *text = get_string_len(env, v, &n);
            if (text == NULL) {
                throw_status(env, DS_ERR_OOM, "json slot");
                return false;
            }
            ds_result_t r = ds_json_parse(text, n, &own->json);
            free(text);
            if (r.status != DS_OK) {
                throw_ds(env, r);
                return false;
            }
            out->kind = DS_SLOT_JSON;
            out->v.json = own->json;
            return true;
        }
        snprintf(msg, sizeof msg, "slot `%s` is Json: want JSON text (a string)", d->name);
        break;
    case DS_SLOT_TYPE_BYTES: {
        bool is_ta = false;
        napi_is_typedarray(env, v, &is_ta);
        if (is_ta) {
            napi_typedarray_type t;
            size_t len = 0, off = 0;
            void *data = NULL;
            napi_value ab;
            napi_get_typedarray_info(env, v, &t, &len, &data, &ab, &off);
            if (t == napi_uint8_array) {
                out->kind = DS_SLOT_BYTES;
                out->v.bytes.data = data;
                out->v.bytes.len = len;
                return true;
            }
        }
        snprintf(msg, sizeof msg, "slot `%s` is Bytes: want a Uint8Array", d->name);
        break;
    }
    case DS_SLOT_TYPE_SCHEMA: {
        js_fact_t *jf = arg_fact(env, v, je);
        if (jf == NULL)
            return false;
        out->kind = DS_SLOT_FACT_REF;
        out->v.ref = jf->fact;
        return true;
    }
    default:
        snprintf(msg, sizeof msg, "slot `%s`: a slot type this binding does not know", d->name);
    }
    napi_throw_type_error(env, NULL, msg);
    return false;
}

/* Slots BY NAME, reordered into declaration order — pyds's `assert_` shape.
   An omitted nullable slot is null ([LNUL.4.1]); an omitted `hydrated_corr`
   is "" (a live fact); any other omission, and any unknown name, is an error.
   The fact's deadline is its schema's TTL: there is no per-fact override. */
/* [LSTR.8.5]: a Json slot given as JSON text is judged as text
   -- its limit, its encoding, its parse, all `ds_json_parse`'s -- before
   [NFCT.2.11]'s step 1, the halted engine. The glue learns which slot is Json
   from the schema, and a halted engine refuses that read ([NCBK.2.9]), so the
   schema's shape is read from the copy the last load left (`snap_take`).
   Each Json slot the host gave a string is judged, in declaration order, and
   the first refused decides; with none refused, the answer is the halt, `r`.
   A schema the copy does not hold, or no copy, is the halt too: step 1
   comes before step 2, the unknown schema. Only text is judged here: any
   other defect of a value is a later step than the halt. */
static napi_value lstr_8_5_text_before_halt(napi_env env, js_engine_t *je,
                                            const char *sname, napi_value obj,
                                            ds_result_t r) {
    napi_valuetype ot;
    napi_typeof(env, obj, &ot);
    for (size_t i = 0; ot == napi_object && i < je->n_snap; i++) {
        const js_schema_snap_t *s = &je->snap[i];
        if (strcmp(s->name, sname) != 0)
            continue;
        for (uint32_t j = 0; j < s->n; j++) {
            bool has = false;
            napi_value key, jv;
            napi_valuetype vt;
            if (!s->json[j])
                continue;
            napi_create_string_utf8(env, s->slot[j], NAPI_AUTO_LENGTH, &key);
            napi_has_own_property(env, obj, key, &has);
            if (!has)
                continue;
            napi_get_property(env, obj, key, &jv);
            napi_typeof(env, jv, &vt);
            if (vt != napi_string)
                continue;
            size_t n = 0;
            char *text = get_string_len(env, jv, &n);
            if (text == NULL)
                return throw_status(env, DS_ERR_OOM, "json slot");
            ds_json_t *tree = NULL;
            ds_result_t pr = ds_json_parse(text, n, &tree);
            free(text);
            if (pr.status != DS_OK)
                return throw_ds(env, pr);
            ds_json_free(tree);
        }
        break;
    }
    return throw_ds(env, r);
}

static napi_value f_assert(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3], names;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    js_engine_t *je = arg_engine(env, argv[0]);
    if (je == NULL)
        return NULL;
    napi_value obj = argv[2];

    char *sname = get_string(env, argv[1]);
    if (sname == NULL)
        return throw_type(env, "schema: want a name");
    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_find(je->e, sname, &schema);
    if (r.status == DS_ERR_ENGINE_HALTED) {
        napi_value done = lstr_8_5_text_before_halt(env, je, sname, obj, r);
        free(sname);
        return done;
    }
    if (r.status != DS_OK) {
        free(sname);
        return throw_ds(env, r);
    }
    if (schema == NULL) {
        char msg[300];
        snprintf(msg, sizeof msg, "no schema named `%s` is registered with this engine", sname);
        free(sname);
        return throw_status(env, DS_ERR_SCHEMA_UNKNOWN, msg);
    }
    free(sname);

    napi_valuetype ot;
    napi_typeof(env, obj, &ot);
    if (ot != napi_object)
        return throw_type(env, "slots: want an object of slot name -> value");

    uint32_t n = 0, given = 0, matched = 0;
    ds_schema_get_slot_count(schema, &n);
    napi_get_property_names(env, obj, &names);
    napi_get_array_length(env, names, &given);

    ds_slot_value_t *vals = calloc(n ? n : 1, sizeof *vals);
    owned_t *own = calloc(n ? n : 1, sizeof *own);
    bool ok = vals != NULL && own != NULL;
    if (!ok)
        throw_status(env, DS_ERR_OOM, "assert");
    for (uint32_t i = 0; ok && i < n; i++) {
        ds_slot_desc_t d;
        bool has = false;
        napi_value key, jv;
        ds_schema_get_slot(schema, i, &d);
        napi_create_string_utf8(env, d.name, NAPI_AUTO_LENGTH, &key);
        napi_has_own_property(env, obj, key, &has);
        if (!has) {
            if (strcmp(d.name, "hydrated_corr") == 0) {
                vals[i].kind = DS_SLOT_STRING;
                vals[i].v.s = "";
                continue;
            }
            if (d.nullable) {
                vals[i].kind = DS_SLOT_NULL;
                continue;
            }
            char msg[300];
            snprintf(msg, sizeof msg, "missing slot `%s`", d.name);
            throw_type(env, msg);
            ok = false;
            break;
        }
        matched++;
        napi_get_property(env, obj, key, &jv);
        ok = js_to_slot(env, je, jv, &d, &vals[i], &own[i]);
    }
    if (ok && matched != given) {
        throw_type(env, "slots: a name that is not a slot of this schema");
        ok = false;
    }

    ds_fact_t *fact = NULL;
    if (ok)
        r = ds_engine_assert(je->e, schema, vals, n, &fact);
    for (uint32_t i = 0; own != NULL && i < n; i++) {
        free(own[i].str);
        if (own[i].json != NULL)
            ds_json_free(own[i].json);
    }
    free(own);
    free(vals);
    if (!ok)
        return NULL;
    if (r.status != DS_OK || fact == NULL)
        return finish(env, r, NULL);
    return finish(env, r, wrap_fact(env, je, fact));
}

/* ── callbacks: libds -> JS ─────────────────────────────────────────────── */

static void put_str(napi_env env, napi_value o, const char *k, const char *s) {
    napi_value v;
    napi_create_string_utf8(env, s ? s : "", NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, o, k, v);
}

/* The fault payloads' strings: NULL means absent, so it goes over as null
   (pyds sends None for the same fields). */
static void put_str_or_null(napi_env env, napi_value o, const char *k, const char *s) {
    napi_value v;
    if (s == NULL)
        napi_get_null(env, &v);
    else
        napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, o, k, v);
}

/* A call's correlation: always a string, the call's `as` value or the one the
   compiler generated for a call with none ([LCRS.3.1], [LCCO.3.4]).
   libds.h says it is never NULL, so a NULL is a runtime defect against
   [LCRS.3.1]: thrown, so the callback is not entered (`cb_invoke`) and the
   error reaches the unraisable hook, never sent over as null or "". */
static bool put_correlation(napi_env env, napi_value o, const char *s) {
    if (s == NULL) {
        napi_throw_error(env, NULL, "libds issued a call with no correlation ([LCRS.3.1])");
        return false;
    }
    put_str(env, o, "correlation", s);
    return true;
}

static void put_null(napi_env env, napi_value o, const char *k);

static void put_u64(napi_env env, napi_value o, const char *k, uint64_t x) {
    napi_value v;
    napi_create_bigint_uint64(env, x, &v);
    napi_set_named_property(env, o, k, v);
}

static void put_i64(napi_env env, napi_value o, const char *k, int64_t x) {
    napi_value v;
    napi_create_bigint_int64(env, x, &v);
    napi_set_named_property(env, o, k, v);
}

static void put_num(napi_env env, napi_value o, const char *k, double x) {
    napi_value v;
    napi_create_double(env, x, &v);
    napi_set_named_property(env, o, k, v);
}

/* A JSON tree as canonical text from libds's serialiser, or null. False,
   with an exception pending, if the serialiser fails. */
static bool json_to_js(napi_env env, const ds_json_t *t, napi_value *out) {
    if (t == NULL)
        return napi_get_null(env, out) == napi_ok;
    char *text = NULL;
    size_t n = 0;
    ds_result_t r = ds_json_serialize(t, &text, &n);
    if (r.status != DS_OK) {
        throw_ds(env, r);
        return false;
    }
    napi_create_string_utf8(env, text, n, out);
    ds_free(text);
    return true;
}

static bool put_json(napi_env env, napi_value o, const char *k, const ds_json_t *t) {
    napi_value v;
    if (!json_to_js(env, t, &v))
        return false;
    napi_set_named_property(env, o, k, v);
    return true;
}

static bool put_fact(napi_env env, js_engine_t *je, napi_value o, const char *k,
                     ds_fact_t *f) {
    napi_value v = wrap_fact(env, je, f);
    if (v == NULL)
        return false;
    napi_set_named_property(env, o, k, v);
    return true;
}

/* pyds's PyErr_WriteUnraisable: take the pending exception and hand it, with
   the callback's name, to the hook lib/index.js registered. A hook that throws
   is dropped, as Python drops one. */
static void report_unraisable(napi_env env, const char *where) {
    js_instance_t *inst = NULL;
    napi_value err = NULL, hook = NULL, undef, args[2], res;
    napi_get_and_clear_last_exception(env, &err);
    napi_get_instance_data(env, (void **) &inst);
    if (inst == NULL || inst->unraisable == NULL
        || napi_get_reference_value(env, inst->unraisable, &hook) != napi_ok || hook == NULL)
        return;
    napi_get_undefined(env, &undef);
    args[0] = err ? err : undef;
    napi_create_string_utf8(env, where, NAPI_AUTO_LENGTH, &args[1]);
    if (napi_call_function(env, undef, hook, 2, args, &res) != napi_ok)
        napi_get_and_clear_last_exception(env, &err);
}

/* One call into JS, in its own handle scope. */
typedef struct {
    js_engine_t    *je;
    napi_env          env;
    napi_handle_scope scope;
    napi_value        fn;
    int               which;
    bool              ran;      /* the function was called, not just its arguments built */
} cb_call_t;

/* The handlers (JS_BINDING.md §3.5): lib/bind.js wraps each, keeps or reports
   its exception itself, and throws it on only so this glue tells libds that it
   failed. */
static bool is_handler(int which) {
    return which == CB_CACHE_SET || which == CB_CACHE_DELETE;
}

/* Whether to enter JS for `which` now: a callback is set, the engine is not
   being torn down, and no earlier JS exception is still on its way out — a
   call would fail then, and reporting would bury that exception. */
static bool cb_begin(js_engine_t *je, int which, cb_call_t *c) {
    bool pending = false;
    if (je->closing || je->cb[which] == NULL)
        return false;
    c->je = je;
    c->env = je->env;
    c->which = which;
    c->ran = false;
    napi_is_exception_pending(c->env, &pending);
    if (pending || napi_open_handle_scope(c->env, &c->scope) != napi_ok)
        return false;
    c->fn = NULL;
    napi_get_reference_value(c->env, je->cb[which], &c->fn);
    if (c->fn == NULL) {            /* collected with its Engine */
        napi_close_handle_scope(c->env, c->scope);
        return false;
    }
    je->in_callback++;
    return true;
}

/* Call it, unless building the arguments already threw. True when the
   callback returned normally; its return value is ignored, as pyds's is. */
static bool cb_invoke(cb_call_t *c, size_t argc, const napi_value *argv) {
    bool pending = false;
    napi_value undef, res;
    napi_is_exception_pending(c->env, &pending);
    if (pending)
        return false;
    napi_get_undefined(c->env, &undef);
    c->ran = true;
    return napi_call_function(c->env, undef, c->fn, argc, argv, &res) == napi_ok;
}

/* Settle a pending exception: a handler's that it threw is cleared, since
   lib/bind.js has it already; any other goes to the unraisable hook, a
   handler's included when building its argument threw and it never ran. True
   when the callback FAILED. */
static bool cb_end(cb_call_t *c) {
    bool pending = false;
    napi_is_exception_pending(c->env, &pending);
    if (pending && c->ran && is_handler(c->which)) {
        napi_value err;
        napi_get_and_clear_last_exception(c->env, &err);
    } else if (pending) {
        report_unraisable(c->env, CB_NAMES[c->which]);
    }
    napi_close_handle_scope(c->env, c->scope);
    c->je->in_callback--;
    return pending;
}

/* What a typed callback answers libds: a callback that failed has
   failed, and libds acts on that — see the file header. */
static ds_result_t cb_status(const cb_call_t *c, bool failed) {
    if (!failed)
        return DS_OK_R;
    if (c->ran && is_handler(c->which))
        return DS_ERR_R(DS_ERR_ACTION_FAILED, "@ds-lang/ds: the handler threw (the error's cause)");
    return DS_ERR_R(DS_ERR_ACTION_FAILED, "@ds-lang/ds: the JS callback threw (reported to the unraisable hook)");
}

/* One stream event as a plain object. Facts go over as handles, which
   lib/index.js wraps as Facts. Common fields always; the rest per kind, as
   pyds's pyds_event_to_dict has them, in camelCase. */
static napi_value event_to_js(napi_env env, js_engine_t *je, const ds_stream_ev_t *ev) {
    napi_value o, arr;
    napi_create_object(env, &o);
    put_u64(env, o, "seq", ev->seq);
    put_u64(env, o, "clockNs", ev->clock_ns);
    put_str(env, o, "kind", ds_names_event_kind(ev->kind));
    switch (ev->kind) {
    case DS_EV_FACT_ASSERT:
        if (!put_fact(env, je, o, "fact", ev->p.fact_assert.fact)) return NULL;
        break;
    case DS_EV_FACT_RETRACT:
        if (!put_fact(env, je, o, "fact", ev->p.fact_retract.fact)) return NULL;
        break;
    case DS_EV_FACT_MODIFY:
        if (!put_fact(env, je, o, "fact", ev->p.fact_modify.fact)) return NULL;
        break;
    case DS_EV_RULE_FIRE_BEGIN:
        put_str(env, o, "ruleName", ev->p.rule_fire_begin.rule_name);
        put_i64(env, o, "timetag", ev->p.rule_fire_begin.timetag);
        break;
    case DS_EV_RULE_FIRE_END:
        put_str(env, o, "ruleName", ev->p.rule_fire_end.rule_name);
        put_i64(env, o, "timetag", ev->p.rule_fire_end.timetag);
        break;
    case DS_EV_ACTION_PUBLISH: {
        /* [NCBK.2.5]: the event's fact is a view, valid for the callback only,
           with no id: a `publish` puts nothing in working memory ([LTIE.4.3]),
           so no handle could reach it afterwards. Its schema and slot values
           are copied here, as pyds copies them, with the values fact_to_js
           gives a fact in working memory. */
        if (ev->p.action_publish.fact == NULL) {
            napi_throw_error(env, NULL, "@ds-lang/ds: action_publish carries no view");
            return NULL;
        }
        napi_value view = fact_to_js(env, je, ev->p.action_publish.fact);
        if (view == NULL)
            return NULL;
        napi_value schema, slots;
        napi_get_named_property(env, view, "schema", &schema);
        napi_get_named_property(env, view, "slots", &slots);
        napi_set_named_property(env, o, "schema", schema);
        napi_set_named_property(env, o, "slots", slots);
        /* The FactExternal another tier's assertExternal takes, copied. */
        napi_set_named_property(env, o, "external",
                                bytes_to_js(env, ev->p.action_publish.external,
                                            ev->p.action_publish.external_len));
        break;
    }
    case DS_EV_ACTION_EMIT:
        if (!put_fact(env, je, o, "fact", ev->p.action_emit.fact)) return NULL;
        break;
    case DS_EV_ACTION_LOG:
        put_str(env, o, "level", ds_names_log_level(ev->p.action_log.level));
        put_str(env, o, "category", ev->p.action_log.category);
        put_str(env, o, "message", ev->p.action_log.message);
        break;
    case DS_EV_ACTION_CACHE_SET:
        put_str(env, o, "key", ev->p.action_cache_set.key);
        if (!put_json(env, o, "valueJson", ev->p.action_cache_set.value)) return NULL;
        put_u64(env, o, "ttlNs", ev->p.action_cache_set.ttl_ns);
        break;
    case DS_EV_ACTION_CACHE_GET:
        put_str(env, o, "key", ev->p.action_cache_get.key);
        if (!put_json(env, o, "valueJson", ev->p.action_cache_get.value)) return NULL;
        break;
    case DS_EV_ACTION_CACHE_DELETE:
        put_str(env, o, "key", ev->p.action_cache_delete.key);
        break;
    case DS_EV_ACTION_CALL: {
        put_str(env, o, "service", ev->p.action_call.service);
        if (!put_correlation(env, o, ev->p.action_call.correlation))
            return NULL;
        napi_value args = args_to_js(env, ev->p.action_call.args, ev->p.action_call.arg_count);
        if (args == NULL) return NULL;
        napi_set_named_property(env, o, "args", args);
        put_i64(env, o, "timetag", ev->p.action_call.timetag);
        put_str(env, o, "ruleName", ev->p.action_call.rule_name);
        break;
    }
    case DS_EV_RULE_LHS_FACTS:
        put_str(env, o, "ruleName", ev->p.rule_lhs_facts.rule_name);
        napi_create_array_with_length(env, ev->p.rule_lhs_facts.fact_count, &arr);
        for (uint32_t i = 0; i < ev->p.rule_lhs_facts.fact_count; i++) {
            napi_value h = wrap_fact(env, je, ev->p.rule_lhs_facts.facts[i]);
            if (h == NULL)
                return NULL;
            napi_set_element(env, arr, i, h);
        }
        napi_set_named_property(env, o, "lhsFacts", arr);
        /* The firing's timetag, as rule_fire_begin carries it ([NCBK.2.12]):
           the key that joins the two, not their positions. */
        put_i64(env, o, "timetag", ev->p.rule_lhs_facts.timetag);
        break;
    case DS_EV_TIMER_ARMED:
        put_str(env, o, "ruleName", ev->p.timer_armed.rule_name);
        put_str(env, o, "timerKind", ev->p.timer_armed.kind);
        put_u64(env, o, "windowNs", ev->p.timer_armed.window_ns);
        put_u64(env, o, "fireAtNs", ev->p.timer_armed.fire_at_ns);
        put_i64(env, o, "timetag", ev->p.timer_armed.timetag);   /* the arming firing's */
        break;
    case DS_EV_TIMER_FIRED:
        /* RESERVED AND NEVER EMITTED ([NCBK.2.4]): libds declares the kind
           and its arm and dispatches neither. Kept so the switch covers the
           enum. */
        put_str(env, o, "ruleName", ev->p.timer_fired.rule_name);
        put_str(env, o, "timerKind", ev->p.timer_fired.kind);
        break;
    /* Fault payloads: the enums as their integer values, which are the proto
       numbers, as pyds sends them. */
    case DS_EV_TYPE_ERROR:
        put_num(env, o, "nodeId", ev->p.type_error.node_id);
        put_str_or_null(env, o, "schemaName", ev->p.type_error.schema_name);
        put_str_or_null(env, o, "slotName", ev->p.type_error.slot_name);
        put_str_or_null(env, o, "actual", ev->p.type_error.actual);
        put_str(env, o, "ruleName", ev->p.type_error.rule_name);   /* never NULL ([LERR.9.11]) */
        break;
    case DS_EV_BOUNDS_ERROR:
        put_num(env, o, "cap", (double) ev->p.bounds_error.cap);
        put_u64(env, o, "limit", ev->p.bounds_error.limit);
        put_u64(env, o, "observed", ev->p.bounds_error.observed);
        put_str_or_null(env, o, "ruleName", ev->p.bounds_error.rule_name);
        put_i64(env, o, "timetag", ev->p.bounds_error.timetag);
        break;
    case DS_EV_ENGINE_ERROR:
        put_num(env, o, "engineFault", (double) ev->p.engine_error.fault);
        put_num(env, o, "nodeId", ev->p.engine_error.node_id);
        put_str(env, o, "ruleName", ev->p.engine_error.rule_name);   /* never NULL ([LERR.9.11]) */
        break;
    case DS_EV_COMPUTATION_ERROR:
        put_num(env, o, "trapKind", (double) ev->p.computation_error.kind);
        put_str(env, o, "ruleName", ev->p.computation_error.rule_name);   /* never NULL ([LERR.9.11]) */
        put_i64(env, o, "timetag", ev->p.computation_error.timetag);
        put_str_or_null(env, o, "schemaName", ev->p.computation_error.schema_name);
        put_str_or_null(env, o, "slotName", ev->p.computation_error.slot_name);
        put_u64(env, o, "factId", ev->p.computation_error.fact_id);
        put_num(env, o, "nodeId", ev->p.computation_error.node_id);
        break;
    case DS_EV_TICK:
        /* clockNs is the monotonic sample; this is the wall sample, UTC ns
           since the Unix epoch, or null while the wall clock has no value
           (a mock clock before wallClockSet, a board with no wall source). */
        if (ev->p.tick.wall_set)
            put_i64(env, o, "wallNs", ev->p.tick.wall_ns);
        else
            put_null(env, o, "wallNs");
        break;
    case DS_EV_PUMP:   /* no payload: what the pump fired is the events after it */
    default:
        break;
    }
    return o;
}

/* The engine's stream callback, registered for the engine's whole life. The
   recorder's atom first (RECTEE1, as pyds orders it), then the JS callback,
   then the fence: a retracted fact is readable during its own FACT_RETRACT and
   dead once the callback returns. */
static ds_result_t on_stream(ds_engine_t *e, const ds_stream_ev_t *ev, void *user) {
    js_engine_t *je = user;
    cb_call_t c;
    if (je->recording && !je->closing)
        ds_rfcs_recorder_on_event(e, ev, &je->rec);
    if (cb_begin(je, CB_STREAM, &c)) {
        napi_value o = event_to_js(c.env, je, ev);
        cb_invoke(&c, 1, &o);
        cb_end(&c);
    }
    if (ev->kind == DS_EV_FACT_RETRACT)
        release_fact(je, ev->p.fact_retract.fact);
    return DS_OK_R;
}

static ds_result_t tr_call(ds_engine_t *e, const ds_call_request_t *req, void *user) {
    (void) e;
    cb_call_t c;
    if (!cb_begin(user, CB_CALL, &c))
        return DS_OK_R;
    napi_value o;
    napi_create_object(c.env, &o);
    put_str(c.env, o, "service", req->service);
    if (put_correlation(c.env, o, req->correlation)) {
        napi_value args = args_to_js(c.env, req->args, req->arg_count);
        if (args != NULL)
            napi_set_named_property(c.env, o, "args", args);
    }
    put_i64(c.env, o, "timetag", req->timetag);
    put_str(c.env, o, "ruleName", req->rule_name);   /* never NULL ([NCBK.2.12]) */
    cb_invoke(&c, 1, &o);
    return cb_status(&c, cb_end(&c));
}

static ds_result_t tr_log(ds_engine_t *e, const ds_log_event_t *ev, void *user) {
    (void) e;
    cb_call_t c;
    if (!cb_begin(user, CB_LOG, &c))
        return DS_OK_R;
    napi_value o;
    napi_create_object(c.env, &o);
    put_str(c.env, o, "level", ds_names_log_level(ev->level));
    put_str(c.env, o, "category", ev->category);
    put_str(c.env, o, "message", ev->message);
    cb_invoke(&c, 1, &o);
    return cb_status(&c, cb_end(&c));
}

static ds_result_t tr_metric(ds_engine_t *e, const ds_metric_t *m, void *user) {
    (void) e;
    cb_call_t c;
    if (!cb_begin(user, CB_METRIC, &c))
        return DS_OK_R;
    napi_value o, labels;
    napi_create_object(c.env, &o);
    put_str(c.env, o, "name", m->name);
    put_str(c.env, o, "kind", ds_names_metric_kind(m->kind));
    put_num(c.env, o, "value", m->value);
    napi_create_object(c.env, &labels);
    for (uint32_t i = 0; i < m->n_labels; i++)
        put_str(c.env, labels, m->labels[i].key ? m->labels[i].key : "", m->labels[i].value);
    napi_set_named_property(c.env, o, "labels", labels);
    cb_invoke(&c, 1, &o);
    return cb_status(&c, cb_end(&c));
}

static ds_result_t tr_cache_set(ds_engine_t *e, const ds_cache_write_t *write, void *user) {
    (void) e;
    cb_call_t c;
    if (!cb_begin(user, CB_CACHE_SET, &c))
        return DS_OK_R;
    napi_value argv[3];
    napi_create_string_utf8(c.env, write->key ? write->key : "", NAPI_AUTO_LENGTH, &argv[0]);
    if (json_to_js(c.env, write->value, &argv[1]))
        napi_create_bigint_uint64(c.env, write->ttl_ns, &argv[2]);
    cb_invoke(&c, 3, argv);
    return cb_status(&c, cb_end(&c));
}

static ds_result_t tr_cache_delete(ds_engine_t *e, const ds_cache_removal_t *removal,
                                   void *user) {
    (void) e;
    cb_call_t c;
    if (!cb_begin(user, CB_CACHE_DELETE, &c))
        return DS_OK_R;
    napi_value argv[2];
    napi_create_string_utf8(c.env, removal && removal->key ? removal->key : "",
                            NAPI_AUTO_LENGTH, &argv[0]);
    napi_create_string_utf8(c.env,
                            removal ? ds_names_cache_removal(removal->reason) : "delete",
                            NAPI_AUTO_LENGTH, &argv[1]);
    cb_invoke(&c, 2, argv);
    return cb_status(&c, cb_end(&c));
}

/* Register or clear one slot libds-side. The stream hook is never cleared:
   it is the handle fence. The two cache slots are one libds registration. */
static ds_result_t register_slot(js_engine_t *je, int which, bool on) {
    ds_engine_t *e = je->e;
    void *u = on ? (void *) je : NULL;
    switch (which) {
    case CB_CALL:
        return ds_engine_set_call_callback(e, on ? tr_call : NULL, u);
    case CB_LOG:
        return ds_engine_set_log_callback(e, on ? tr_log : NULL, u);
    case CB_METRIC:
        return ds_engine_set_metric_callback(e, on ? tr_metric : NULL, u);
    default:
        return DS_OK_R;
    }
}

/* ── exported functions ─────────────────────────────────────────────────── */

#define ARGS(nargs)                                                         \
    size_t argc = (nargs);                                                  \
    napi_value argv[(nargs) ? (nargs) : 1];                                 \
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL)

#define ENGINE_ARG                                                          \
    js_engine_t *je = arg_engine(env, argv[0]);                           \
    if (je == NULL)                                                         \
        return NULL

/* init(DsError, unraisableHook) — lib/index.js hands over the error class and
   the hook a throwing callback's exception is reported to. */
static napi_value f_init(napi_env env, napi_callback_info info) {
    ARGS(2);
    js_instance_t *inst = NULL;
    napi_get_instance_data(env, (void **) &inst);
    if (inst == NULL)
        return throw_status(env, DS_ERR_INTERNAL, "instance data missing");
    if (inst->error_ctor != NULL)
        napi_delete_reference(env, inst->error_ctor);
    if (inst->unraisable != NULL)
        napi_delete_reference(env, inst->unraisable);
    inst->error_ctor = inst->unraisable = NULL;
    napi_create_reference(env, argv[0], 1, &inst->error_ctor);
    if (argc > 1)
        napi_create_reference(env, argv[1], 1, &inst->unraisable);
    return NULL;
}

/* An engine identity argument of newEngine ([NLFC.1.2]): undefined or null is
   none, a string is taken, anything else is a TypeError. A string holding
   U+0000 is refused too, because a C string cannot carry it; pyds refuses it
   the same way. So is one holding a lone surrogate, which has no UTF-8: libds
   keeps the identity and records it in the stream header without asking
   whether it is well-formed (get_text), and pyds's str refuses one too.
   `*out` is the caller's to free. */
static bool opt_id_arg(napi_env env, napi_value v, const char *what, char **out) {
    *out = NULL;
    napi_valuetype t;
    napi_typeof(env, v, &t);
    if (t == napi_undefined || t == napi_null)
        return true;
    char msg[96];
    if (t != napi_string) {
        snprintf(msg, sizeof msg, "%s: want a string or null", what);
        napi_throw_type_error(env, NULL, msg);
        return false;
    }
    size_t n = 0;
    bool lone = false;
    char *s = get_text(env, v, &n, &lone);
    if (s == NULL) {
        throw_status(env, DS_ERR_OOM, what);
        return false;
    }
    if (strlen(s) != n || lone) {
        free(s);
        snprintf(msg, sizeof msg, "%s: a string holding %s", what,
                 lone ? "a lone surrogate" : "U+0000");
        napi_throw_type_error(env, NULL, msg);
        return false;
    }
    *out = s;
    return true;
}

/* newEngine(runId, tierId): each a string or null, the engine's identity as
   `ds_engine_config_t` takes it ([NLFC.1.2]). libds copies both at
   ds_engine_new, so they are freed straight after; it reads "" as absent. */
static napi_value f_new_engine(napi_env env, napi_callback_info info) {
    ARGS(2);
    ds_engine_config_t cfg;
    ds_engine_t *e = NULL;
    memset(&cfg, 0, sizeof cfg);
    char *run_id = NULL, *tier_id = NULL;
    if (argc > 0 && !opt_id_arg(env, argv[0], "runId", &run_id))
        return NULL;
    if (argc > 1 && !opt_id_arg(env, argv[1], "tierId", &tier_id)) {
        free(run_id);
        return NULL;
    }
    cfg.run_id = run_id;
    cfg.tier_id = tier_id;
    ds_result_t r = ds_engine_new(&cfg, &e);
    free(run_id);
    free(tier_id);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    js_engine_t *je = calloc(1, sizeof *je);
    if (je == NULL) {
        ds_engine_free(e);
        return throw_status(env, DS_ERR_OOM, "engine");
    }
    je->e = e;
    je->env = env;
    r = ds_engine_set_stream_callback(e, on_stream, je);
    if (r.status != DS_OK) {
        napi_value err = make_ds_error(env, r.status, r.detail);
        ds_engine_free(e);
        free(je);
        napi_throw(env, err);
        return NULL;
    }
    napi_value ext;
    napi_create_external(env, je, engine_finalize, NULL, &ext);
    return ext;
}

static napi_value f_close(napi_env env, napi_callback_info info) {
    ARGS(1);
    void *p = NULL;
    if (napi_get_value_external(env, argv[0], &p) != napi_ok || p == NULL)
        return throw_type(env, "not an engine handle");
    /* From inside a callback, libds is mid-dispatch on this engine: freeing it
       there would pull the engine out from under its own caller. */
    if (((js_engine_t *) p)->in_callback > 0)
        return throw_status(env, DS_ERR_STATE, "close() from inside one of the engine's callbacks");
    engine_close(env, p);           /* idempotent */
    return NULL;
}

/* A function or null, else a TypeError. */
static bool arg_callback(napi_env env, napi_value v, napi_value *out, const char *what) {
    napi_valuetype t;
    napi_typeof(env, v, &t);
    if (t == napi_null || t == napi_undefined) {
        *out = NULL;
        return true;
    }
    if (t == napi_function) {
        *out = v;
        return true;
    }
    char msg[128];
    snprintf(msg, sizeof msg, "%s: want a function or null", what);
    napi_throw_type_error(env, NULL, msg);
    return false;
}

/* Register libds-side whatever the slots now hold. */
static ds_result_t register_current(js_engine_t *je, int which) {
    if (which != CB_CACHE_SET && which != CB_CACHE_DELETE)
        return register_slot(je, which, je->cb[which] != NULL);
    bool set_on = je->cb[CB_CACHE_SET] != NULL, del_on = je->cb[CB_CACHE_DELETE] != NULL;
    return ds_engine_cache_callbacks(je->e, DS_CACHE_CB_ABI_VERSION,
                                     set_on ? tr_cache_set : NULL,
                                     del_on ? tr_cache_delete : NULL,
                                     (set_on || del_on) ? (void *) je : NULL);
}

/* Swap the slots' weak references (one, or the cache pair): pyds's order —
   the libds registration first, and the old references dropped only once it
   succeeded; on failure the old ones are put back. */
static napi_value set_slots(napi_env env, js_engine_t *je, const int *which,
                            napi_value const *fns, int n) {
    napi_ref nref[2] = { NULL, NULL }, old[2];
    for (int i = 0; i < n; i++)
        if (fns[i] != NULL)
            napi_create_reference(env, fns[i], 0, &nref[i]);
    for (int i = 0; i < n; i++) {
        old[i] = je->cb[which[i]];
        je->cb[which[i]] = nref[i];
    }
    ds_result_t r = register_current(je, which[0]);
    for (int i = 0; i < n; i++) {
        napi_ref drop = r.status == DS_OK ? old[i] : nref[i];
        if (r.status != DS_OK)
            je->cb[which[i]] = old[i];
        if (drop != NULL)
            napi_delete_reference(env, drop);
    }
    return finish(env, r, NULL);
}

/* setCallback(engine, name, fn | null) — every single-callback slot; the
   cache pair has its own call, as in pyds. */
static napi_value f_set_callback(napi_env env, napi_callback_info info) {
    ARGS(3);
    ENGINE_ARG;
    char *name = get_string(env, argv[1]);
    int which = -1;
    for (int i = 0; name != NULL && i < CB_CACHE_SET; i++)
        if (strcmp(name, CB_NAMES[i]) == 0)
            which = i;
    free(name);
    if (which < 0)
        return throw_type(env, "setCallback: unknown callback name");
    napi_value fn;
    if (!arg_callback(env, argv[2], &fn, CB_NAMES[which]))
        return NULL;
    return set_slots(env, je, &which, &fn, 1);
}

/* setCacheCallbacks(engine, set | null, delete | null) — one libds
   registration for the pair, as ds_engine_cache_callbacks has it. */
static napi_value f_set_cache_callbacks(napi_env env, napi_callback_info info) {
    ARGS(3);
    ENGINE_ARG;
    napi_value fns[2];
    static const int which[2] = { CB_CACHE_SET, CB_CACHE_DELETE };
    if (!arg_callback(env, argv[1], &fns[0], "cache set")
        || !arg_callback(env, argv[2], &fns[1], "cache delete"))
        return NULL;
    return set_slots(env, je, which, fns, 2);
}

/* cacheSeed(engine, key, json, ttlNs) — JSON text in, parsed by libds,
   and the tree freed here: ds_engine_cache_seed copies it. */
static napi_value f_cache_seed(napi_env env, napi_callback_info info) {
    ARGS(4);
    ENGINE_ARG;
    uint64_t ttl = 0;
    if (!get_u64(env, argv[3], &ttl, "ttlNs"))
        return NULL;
    size_t text_len = 0;
    char *key = get_string(env, argv[1]);
    char *text = get_string_len(env, argv[2], &text_len);
    if (key == NULL || text == NULL) {
        free(key);
        free(text);
        return throw_type(env, "cache.seed: want a key and JSON text");
    }
    /* The text's whole length, as for a Json slot (LSTR.1.5). */
    ds_json_t *tree = NULL;
    ds_result_t r = ds_json_parse(text, text_len, &tree);
    free(text);
    if (r.status == DS_OK) {
        r = ds_engine_cache_seed(je->e, key, tree, ttl);
        ds_json_free(tree);
    }
    free(key);
    return finish(env, r, NULL);
}

static napi_value f_load_dsc(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[1], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[1], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "loadDsc: want a Uint8Array");
    ds_result_t r = ds_engine_load_dsc(je->e, data, len);
    if (r.status == DS_OK)
        snap_take(je);   /* the program's shape, for a halted engine's assert */
    return finish(env, r, NULL);
}

static napi_value f_schema_count(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    size_t n = 0;
    ds_result_t r = ds_engine_schema_count(je->e, &n);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_double(env, (double) n, &out);
    return out;
}

static napi_value f_schema_at(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint32_t i = 0;
    const ds_schema_t *s = NULL;
    if (napi_get_value_uint32(env, argv[1], &i) != napi_ok)
        return throw_type(env, "schemaAt: want an index");
    ds_result_t r = ds_engine_schema_at(je->e, i, &s);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return schema_to_js(env, s);
}

/* NFCT.1.4.6: slotConvert(engine, schema, slot, value, toStored), a number
   through a slot's unit conversion. A name the engine has no schema or slot by
   is DS_ERR_SCHEMA_UNKNOWN or DS_ERR_SLOT_UNKNOWN, as an assert's is. A value
   is taken as a slot's is: an Int as a BigInt or a safe integer Number, a
   Float as a Number. A value that is neither for the slot reaches libds with
   the kind it has, a Bool as one and a Number that is no Int as a Float, and
   libds refuses it by kind. An Int comes back as a BigInt, a Float as a
   Number. */
static napi_value f_slot_convert(napi_env env, napi_callback_info info) {
    ARGS(5);
    ENGINE_ARG;
    bool to_stored = false;
    if (napi_get_value_bool(env, argv[4], &to_stored) != napi_ok)
        return throw_type(env, "slotConvert: want a boolean direction");
    char *schema_name = get_string(env, argv[1]);
    if (schema_name == NULL)
        return throw_type(env, "slotConvert: want a schema name");
    const ds_schema_t *s = NULL;
    ds_result_t r = ds_engine_schema_find(je->e, schema_name, &s);
    free(schema_name);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    if (s == NULL)
        return throw_status(env, DS_ERR_SCHEMA_UNKNOWN,
                            "the engine has no schema of that name");
    char *slot_name = get_string(env, argv[2]);
    if (slot_name == NULL)
        return throw_type(env, "slotConvert: want a slot name");
    uint32_t n = 0, index = 0;
    ds_slot_desc_t d;
    memset(&d, 0, sizeof d);
    r = ds_schema_get_slot_count(s, &n);
    for (index = 0; r.status == DS_OK && index < n; index++) {
        r = ds_schema_get_slot(s, index, &d);
        if (r.status == DS_OK && d.name != NULL && strcmp(d.name, slot_name) == 0)
            break;
    }
    free(slot_name);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    if (index == n)
        return throw_status(env, DS_ERR_SLOT_UNKNOWN,
                            "the schema has no slot of that name");

    ds_slot_value_t in;
    memset(&in, 0, sizeof in);
    napi_valuetype vt;
    napi_typeof(env, argv[3], &vt);
    if (vt == napi_bigint) {
        bool lossless = false;
        in.kind = DS_SLOT_INT;
        napi_get_value_bigint_int64(env, argv[3], &in.v.i, &lossless);
        if (!lossless)
            return throw_status(env, DS_ERR_SLOT_TYPE_MISMATCH,
                                "a BigInt outside int64");
    } else if (vt == napi_number) {
        double x = 0;
        napi_get_value_double(env, argv[3], &x);
        /* Number.isSafeInteger, exactly, as js_to_slot. */
        if (d.type != DS_SLOT_TYPE_FLOAT && isfinite(x) && x == trunc(x)
            && fabs(x) <= 9007199254740991.0) {
            in.kind = DS_SLOT_INT;
            in.v.i = (int64_t) x;
        } else {
            in.kind = DS_SLOT_FLOAT;
            in.v.f = x;
        }
    } else if (vt == napi_boolean) {
        in.kind = DS_SLOT_BOOL;
        napi_get_value_bool(env, argv[3], &in.v.b);
    } else {
        return throw_type(env, "slotConvert: want a BigInt or a Number");
    }

    ds_slot_value_t out;
    r = to_stored ? ds_schema_slot_to_stored(s, index, &in, &out)
                  : ds_schema_slot_from_stored(s, index, &in, &out);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value v;
    if (out.kind == DS_SLOT_FLOAT)
        napi_create_double(env, out.v.f, &v);
    else
        napi_create_bigint_int64(env, out.v.i, &v);
    return v;
}

/* NCBK.10.4: a FactExternal another engine handed out, asserted here. libds
   resolves its references and refuses the whole record, asserting nothing;
   it returns no fact. */
static napi_value f_assert_external(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[1], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[1], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "assertExternal: want a Uint8Array");
    return finish(env, ds_engine_assert_external(je->e, data, len), NULL);
}

/* applyExternalAssert(engine, body) -> { factIds, recordedIds }
 *
 * RFCS.24.2: one recorded ExternalAssert, its atom body as framed, applied as
 * libds's replayer applies it (ds_rfcs_apply_external_assert): one input, the
 * recorded ttl_ns on the received fact, no pump. factIds[i] is this engine's
 * id for recordedIds[i], in RFCS.24.3's order. A refusal throws, with nothing
 * applied but on DS_ERR_FS_DIVERGENCE: that is a delivery that refused, or
 * one that asserted a different number of facts than the record lists. The
 * arrays start small and are sized to what libds says it needs. */
static napi_value f_apply_external_assert(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[1], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[1], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "applyExternalAssert: want a Uint8Array");
    size_t cap = 8, n = 0;
    uint64_t *ids = NULL, *rec = NULL;
    ds_result_t r;
    for (;;) {
        ids = malloc(cap * sizeof *ids);
        rec = malloc(cap * sizeof *rec);
        if (ids == NULL || rec == NULL) {
            free(ids);
            free(rec);
            return throw_status(env, DS_ERR_OOM, "applyExternalAssert");
        }
        n = 0;
        r = ds_rfcs_apply_external_assert(je->e, data, len, ids, rec, cap, &n);
        if (r.status != DS_ERR_INVAL || n <= cap)
            break;
        free(ids);
        free(rec);
        cap = n;                    /* too short: libds said how long */
    }
    napi_value out = NULL;
    if (r.status == DS_OK) {
        napi_value fact_ids, recorded_ids, v;
        napi_create_object(env, &out);
        napi_create_array_with_length(env, n, &fact_ids);
        napi_create_array_with_length(env, n, &recorded_ids);
        for (size_t i = 0; i < n; i++) {
            napi_create_bigint_uint64(env, ids[i], &v);
            napi_set_element(env, fact_ids, (uint32_t) i, v);
            napi_create_bigint_uint64(env, rec[i], &v);
            napi_set_element(env, recorded_ids, (uint32_t) i, v);
        }
        napi_set_named_property(env, out, "factIds", fact_ids);
        napi_set_named_property(env, out, "recordedIds", recorded_ids);
    }
    free(ids);
    free(rec);
    return finish(env, r, out);
}

static napi_value f_retract(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    js_fact_t *jf = arg_fact(env, argv[1], je);
    if (jf == NULL)
        return NULL;
    /* The FACT_RETRACT event releases the handle, through on_stream. */
    return finish(env, ds_engine_retract(je->e, jf->fact), NULL);
}

static napi_value f_fact_id(napi_env env, napi_callback_info info) {
    ARGS(1);
    void *p = NULL;
    if (napi_get_value_external(env, argv[0], &p) != napi_ok || p == NULL)
        return throw_type(env, "not a fact handle");
    napi_value out;
    napi_create_bigint_uint64(env, ((js_fact_t *) p)->id, &out);
    return out;
}

static napi_value f_fact_alive(napi_env env, napi_callback_info info) {
    ARGS(1);
    void *p = NULL;
    if (napi_get_value_external(env, argv[0], &p) != napi_ok || p == NULL)
        return throw_type(env, "not a fact handle");
    napi_value out;
    napi_get_boolean(env, ((js_fact_t *) p)->eng != NULL, &out);
    return out;
}

static napi_value f_fact_read(napi_env env, napi_callback_info info) {
    ARGS(1);
    js_fact_t *jf = arg_fact(env, argv[0], NULL);
    if (jf == NULL)
        return NULL;
    if (jf->eng->e == NULL)
        return throw_status(env, DS_ERR_STATE, "the engine is closed");
    return fact_to_js(env, jf->eng, jf->fact);
}

typedef struct { ds_fact_t **v; size_t n, cap; } fact_list_t;

static ds_result_t collect(const ds_fact_t *f, void *user) {
    fact_list_t *l = user;
    if (l->n == l->cap) {
        size_t ncap = l->cap ? l->cap * 2 : 32;
        ds_fact_t **nv = realloc(l->v, ncap * sizeof *nv);
        if (nv == NULL)
            return DS_ERR_R(DS_ERR_OOM, "facts");
        l->v = nv;
        l->cap = ncap;
    }
    l->v[l->n++] = (ds_fact_t *) f;
    return DS_OK_R;
}

static napi_value f_facts(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    const ds_schema_t *schema = NULL;
    napi_valuetype vt = napi_undefined;
    if (argc > 1)
        napi_typeof(env, argv[1], &vt);
    if (vt != napi_string && vt != napi_null && vt != napi_undefined)
        return throw_type(env, "facts: schema: want a name or null");
    if (vt == napi_string) {
        char *name = get_string(env, argv[1]);
        if (name == NULL)
            return throw_status(env, DS_ERR_OOM, "facts");
        ds_result_t r = ds_engine_schema_find(je->e, name, &schema);
        free(name);
        if (r.status != DS_OK)
            return throw_ds(env, r);
        if (schema == NULL)
            return throw_status(env, DS_ERR_SCHEMA_UNKNOWN, "facts: no such schema");
    }
    fact_list_t l = { NULL, 0, 0 };
    /* Collect, then convert: the visitor must not re-enter anything. */
    ds_result_t r = ds_engine_for_each_fact(je->e, schema, collect, &l);
    if (r.status != DS_OK) {
        free(l.v);
        return throw_ds(env, r);
    }
    /* Handles, which lib/bind.js makes Facts: a fact is read through its
       handle, as one assert returns is. */
    napi_value arr;
    napi_create_array_with_length(env, l.n, &arr);
    for (size_t i = 0; i < l.n; i++) {
        napi_value fv = wrap_fact(env, je, l.v[i]);
        if (fv == NULL) {
            free(l.v);
            return NULL;
        }
        napi_set_element(env, arr, (uint32_t) i, fv);
    }
    free(l.v);
    return arr;
}

/* factById(engine, id) -> handle | null: the live fact with this engine-local
   id, as pyds's fact_handle. A handle is the fact's address, so a clone's
   facts have handles of their own: an integrator that clones an engine and
   then retracts a fact asserted before the clone has only the id to go on.
   Walks working memory, O(live facts). */
typedef struct { uint64_t want; ds_fact_t *found; } by_id_t;

static ds_result_t by_id(const ds_fact_t *f, void *user) {
    by_id_t *w = user;
    uint64_t id = 0;
    ds_result_t r = ds_fact_get_id(f, &id);
    if (r.status != DS_OK)
        return r;
    if (id == w->want)
        w->found = (ds_fact_t *) f;
    return DS_OK_R;
}

static napi_value f_fact_by_id(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    by_id_t w = { 0, NULL };
    if (!get_u64(env, argv[1], &w.want, "factById"))
        return NULL;
    ds_result_t r = ds_engine_for_each_fact(je->e, NULL, by_id, &w);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    if (w.found == NULL) {
        napi_value nul;
        napi_get_null(env, &nul);
        return nul;
    }
    return wrap_fact(env, je, w.found);
}

/* mem(engine) -> { wmFactCount, ..., totalBytes }: ds_engine_mem, one key per
   ds_engine_mem_t field, as Numbers. */
static napi_value f_mem(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    ds_engine_mem_t m;
    ds_result_t r = ds_engine_mem(je->e, &m);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value o, v;
    napi_create_object(env, &o);
#define MEM(key, field) napi_create_double(env, (double) m.field, &v); napi_set_named_property(env, o, key, v)
    MEM("wmFactCount", wm_fact_count);
    MEM("wmFactBytes", wm_fact_bytes);
    MEM("wmIndexBytes", wm_index_bytes);
    MEM("alphaNodeCount", alpha_node_count);
    MEM("alphaMatchCount", alpha_match_count);
    MEM("alphaIndexBytes", alpha_index_bytes);
    MEM("betaNodeCount", beta_node_count);
    MEM("betaTokenCount", beta_token_count);
    MEM("betaTokenBytes", beta_token_bytes);
    MEM("betaIndexBytes", beta_index_bytes);
    MEM("internCount", intern_count);
    MEM("internStringBytes", intern_string_bytes);
    MEM("internIndexBytes", intern_index_bytes);
    MEM("poolReservedBytes", pool_reserved_bytes);
    MEM("totalBytes", total_bytes);
#undef MEM
    return o;
}

static napi_value f_fact_count(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    size_t n = 0;
    ds_result_t r = ds_engine_fact_count(je->e, &n);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_double(env, (double) n, &out);
    return out;
}

/* The halt latch ([NCBK.2.11]): null while the engine runs, else the
   EngineFault that halted it, as its proto number, as the engine_error
   event's engineFault carries it. */
static napi_value f_halted(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    ds_result_t r = ds_engine_halted(je->e, &halted, &fault);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    if (halted)
        napi_create_double(env, (double) fault, &out);
    else
        napi_get_null(env, &out);
    return out;
}

static napi_value f_pump(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    return finish(env, ds_engine_pump(je->e), NULL);
}

static napi_value f_clock_mode(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    ds_clock_mode_t m = DS_CLOCK_LIVE;
    ds_result_t r = ds_engine_clock_mode(je->e, &m);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_string_utf8(env, m == DS_CLOCK_MOCK ? "mock" : "live", NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value f_clock_set_mode(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    char *m = get_string(env, argv[1]);
    ds_clock_mode_t mode;
    if (m != NULL && strcmp(m, "mock") == 0)
        mode = DS_CLOCK_MOCK;
    else if (m != NULL && strcmp(m, "live") == 0)
        mode = DS_CLOCK_LIVE;
    else {
        free(m);
        return throw_type(env, "clockSetMode: want \"live\" or \"mock\"");
    }
    free(m);
    return finish(env, ds_engine_clock_set_mode(je->e, mode), NULL);
}

static napi_value f_clock_now(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    uint64_t ns = 0;
    ds_result_t r = ds_engine_clock_now(je->e, &ns);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_bigint_uint64(env, ns, &out);
    return out;
}

static napi_value f_clock_next_deadline(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    uint64_t ns = 0;
    bool has = false;
    ds_result_t r = ds_engine_next_deadline_ns(je->e, &ns, &has);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    if (has)
        napi_create_bigint_uint64(env, ns, &out);
    else
        napi_get_null(env, &out);
    return out;
}

static napi_value f_clock_set(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint64_t ns = 0;
    if (!get_u64(env, argv[1], &ns, "clockSet"))
        return NULL;
    return finish(env, ds_engine_clock_set(je->e, ns), NULL);
}

static napi_value f_clock_advance(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint64_t ns = 0;
    if (!get_u64(env, argv[1], &ns, "clockAdvance"))
        return NULL;
    return finish(env, ds_engine_clock_advance(je->e, ns), NULL);
}

/* wallClockSet(engine, utcNs): the mock wall clock, UTC ns since the Unix
   epoch, any instant, earlier or later than before. Not a sample: the next
   input or pump observes it. DS_ERR_STATE in live mode. */
static napi_value f_wall_clock_set(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    int64_t ns = 0;
    if (!get_i64(env, argv[1], &ns, "wallClockSet"))
        return NULL;
    return finish(env, ds_engine_wall_clock_set(je->e, ns), NULL);
}

static napi_value f_platform_signature(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    ds_platform_signature_t sig;
    ds_result_t r = ds_engine_get_platform_signature(je->e, &sig);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value obj, tmp, arr;
    napi_create_object(env, &obj);
#define SIGSTR(field, key)                                                  \
    napi_create_string_utf8(env, sig.field ? sig.field : "", NAPI_AUTO_LENGTH, &tmp); \
    napi_set_named_property(env, obj, key, tmp);
    SIGSTR(os_family, "osFamily")
    SIGSTR(cpu_arch, "cpuArch")
    SIGSTR(libc, "libc")
    SIGSTR(compiler, "compiler")
    SIGSTR(libds_version, "libdsVersion")
#undef SIGSTR
    napi_create_array_with_length(env, sig.n_backends, &arr);
    for (size_t i = 0; i < sig.n_backends; i++) {
        napi_create_string_utf8(env, sig.backends[i], NAPI_AUTO_LENGTH, &tmp);
        napi_set_element(env, arr, (uint32_t) i, tmp);
    }
    napi_set_named_property(env, obj, "backends", arr);
    return obj;
}

/* ── introspection ──────────────────────────────────────────────────────── */

static void put_null(napi_env env, napi_value o, const char *k) {
    napi_value v;
    napi_get_null(env, &v);
    napi_set_named_property(env, o, k, v);
}

static void put_bool(napi_env env, napi_value o, const char *k, bool b) {
    napi_value v;
    napi_get_boolean(env, b, &v);
    napi_set_named_property(env, o, k, v);
}

/* A ds_rule_meta_view_t, each optional field null when its atom is absent —
   pyds's RuleMeta, as a plain object. */
static napi_value rule_meta_to_js(napi_env env, const ds_rule_meta_view_t *v) {
    napi_value o;
    napi_create_object(env, &o);
    put_str(env, o, "ruleName", v->rule_name);
    if (v->has_cool)
        put_u64(env, o, "coolWindowNs", v->cool_window_ns);
    else
        put_null(env, o, "coolWindowNs");
    if (v->has_srcr) {
        put_str_or_null(env, o, "srcFile", v->src_file);
        put_num(env, o, "srcLine", v->src_line);
        put_num(env, o, "srcCol", v->src_col);
    } else {
        put_null(env, o, "srcFile");
        put_null(env, o, "srcLine");
        put_null(env, o, "srcCol");
    }
    if (v->has_dnam)
        put_str_or_null(env, o, "debugNameTemplate", v->debug_name_template);
    else
        put_null(env, o, "debugNameTemplate");
    return o;
}

static napi_value f_rule_meta_count(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    size_t n = 0;
    ds_result_t r = ds_engine_rule_meta_count(je->e, &n);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_double(env, (double) n, &out);
    return out;
}

static napi_value f_rule_meta_at(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint32_t i = 0;
    if (napi_get_value_uint32(env, argv[1], &i) != napi_ok)
        return throw_type(env, "ruleMetaAt: want an index");
    ds_rule_meta_view_t v;
    ds_result_t r = ds_engine_rule_meta_at(je->e, i, &v);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return rule_meta_to_js(env, &v);
}

/* A ds_line_span_view_t ([NDBG.3.1]): the node, the module it is in, and its
   1-based line and column there. pyds's LineSpan, as a plain object. */
static napi_value line_span_to_js(napi_env env, const ds_line_span_view_t *v) {
    napi_value o;
    napi_create_object(env, &o);
    put_num(env, o, "nodeId", v->node_id);
    put_num(env, o, "moduleId", v->module_id);
    put_str_or_null(env, o, "file", v->ds_file);
    put_num(env, o, "line", v->ds_line);
    put_num(env, o, "column", v->ds_col);
    return o;
}

static napi_value f_line_span_count(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    size_t n = 0;
    ds_result_t r = ds_engine_line_span_count(je->e, &n);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_double(env, (double) n, &out);
    return out;
}

static napi_value f_line_span_at(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint32_t i = 0;
    if (napi_get_value_uint32(env, argv[1], &i) != napi_ok)
        return throw_type(env, "lineSpanAt: want an index");
    ds_line_span_view_t v;
    ds_result_t r = ds_engine_line_span_at(je->e, i, &v);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return line_span_to_js(env, &v);
}

/* A node with no LineSpan, an alpha among them ([RDSC.14.3.6]), is libds's
   DS_ERR_NOT_FOUND ([NDBG.7.1]), thrown as a DsError like every other. */
static napi_value f_line_span_find(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint32_t id = 0;
    if (napi_get_value_uint32(env, argv[1], &id) != napi_ok)
        return throw_type(env, "lineSpanFind: want a node id");
    ds_line_span_view_t v;
    ds_result_t r = ds_engine_line_span_find(je->e, id, &v);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return line_span_to_js(env, &v);
}

/* getJustifiers(engine, factId) -> [{ timetag, ruleName }] (RDAP1b). The
   arrays and each name are libds's, released with ds_free (IALC.4.3). */
static napi_value f_get_justifiers(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint64_t id = 0;
    if (!get_u64(env, argv[1], &id, "factId"))
        return NULL;
    int64_t *tts = NULL;
    char **names = NULL;
    uint32_t n = 0;
    ds_result_t r = ds_engine_get_justifiers(je->e, id, &tts, &names, &n);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value arr, o;
    napi_create_array_with_length(env, n, &arr);
    for (uint32_t i = 0; i < n; i++) {
        napi_create_object(env, &o);
        put_i64(env, o, "timetag", tts[i]);
        put_str(env, o, "ruleName", names[i]);
        napi_set_element(env, arr, i, o);
        ds_free(names[i]);
    }
    ds_free(names);
    ds_free(tts);
    return arr;
}

/* The three Rete walks call back into C with strings valid only for the
   call; each builds its JS objects there and then. No JS runs. */
typedef struct {
    napi_env   env;
    napi_value arr;
    uint32_t   n;
} js_list_t;

static void list_push(js_list_t *l, napi_value v) {
    napi_set_element(l->env, l->arr, l->n++, v);
}

static void on_rete_node(const char *id, const char *kind, const char *label,
                         const char *filter, uint32_t occupancy, bool is_negative,
                         void *user) {
    js_list_t *l = user;
    napi_value o;
    napi_create_object(l->env, &o);
    put_str(l->env, o, "id", id);
    put_str(l->env, o, "kind", kind);
    put_str(l->env, o, "label", label);
    put_str(l->env, o, "filter", filter);
    /* UINT32_MAX is libds's "not populated" (the engine is not paused). */
    if (occupancy == UINT32_MAX)
        put_null(l->env, o, "occupancy");
    else
        put_num(l->env, o, "occupancy", occupancy);
    put_bool(l->env, o, "isNegative", is_negative);
    list_push(l, o);
}

static void on_rete_edge(const char *from_id, const char *to_id, void *user) {
    js_list_t *l = user;
    napi_value o;
    napi_create_object(l->env, &o);
    put_str(l->env, o, "fromId", from_id);
    put_str(l->env, o, "toId", to_id);
    list_push(l, o);
}

/* A rule name or null/undefined for "every rule". False after throwing. */
static bool arg_rule_filter(napi_env env, napi_value v, char **out) {
    napi_valuetype t;
    napi_typeof(env, v, &t);
    *out = NULL;
    if (t == napi_null || t == napi_undefined)
        return true;
    if (t != napi_string) {
        napi_throw_type_error(env, NULL, "ruleFilter: want a rule name or null");
        return false;
    }
    *out = get_string(env, v);
    if (*out == NULL) {
        throw_status(env, DS_ERR_OOM, "ruleFilter");
        return false;
    }
    return true;
}

/* reteNetwork(engine, ruleFilter, includeOccupancy) -> { nodes, edges } (RDAP1f). */
static napi_value f_rete_network(napi_env env, napi_callback_info info) {
    ARGS(3);
    ENGINE_ARG;
    char *filter = NULL;
    bool occ = false;
    if (!arg_rule_filter(env, argv[1], &filter))
        return NULL;
    napi_get_value_bool(env, argv[2], &occ);
    js_list_t nodes = { env, NULL, 0 }, edges = { env, NULL, 0 };
    napi_create_array(env, &nodes.arr);
    napi_create_array(env, &edges.arr);
    ds_result_t r = ds_engine_rete_network(je->e, filter, occ, on_rete_node, &nodes,
                                           on_rete_edge, &edges);
    free(filter);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    napi_create_object(env, &out);
    napi_set_named_property(env, out, "nodes", nodes.arr);
    napi_set_named_property(env, out, "edges", edges.arr);
    return out;
}

static void on_trace(const char *node_id, const char *node_kind, const char *result,
                     const char *detail, void *user) {
    js_list_t *l = user;
    napi_value o;
    napi_create_object(l->env, &o);
    put_str(l->env, o, "nodeId", node_id);
    put_str(l->env, o, "nodeKind", node_kind);
    put_str(l->env, o, "result", result);
    put_str(l->env, o, "detail", detail);
    list_push(l, o);
}

/* reteMatchTrace(engine, factId) -> [{ nodeId, nodeKind, result, detail }] (RDAP1c). */
static napi_value f_rete_match_trace(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    uint64_t id = 0;
    if (!get_u64(env, argv[1], &id, "factId"))
        return NULL;
    js_list_t l = { env, NULL, 0 };
    napi_create_array(env, &l.arr);
    ds_result_t r = ds_engine_rete_match_trace(je->e, id, on_trace, &l);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return l.arr;
}

static void on_refract(const char *rule_name, const char *reason, const char *detail,
                       const uint64_t *fact_ids, uint32_t fact_count, void *user) {
    js_list_t *l = user;
    napi_value o, ids, id;
    napi_create_object(l->env, &o);
    put_str(l->env, o, "ruleName", rule_name);
    put_str(l->env, o, "reason", reason);
    put_str(l->env, o, "detail", detail);
    /* BigInt, as a fact id is everywhere else in @ds-lang/ds. Every fact an
       entry names is live ([NDBG.4.3]). */
    napi_create_array_with_length(l->env, fact_count, &ids);
    for (uint32_t i = 0; i < fact_count; i++) {
        napi_create_bigint_uint64(l->env, fact_ids[i], &id);
        napi_set_element(l->env, ids, i, id);
    }
    napi_set_named_property(l->env, o, "factIds", ids);
    list_push(l, o);
}

/* refractedActivations(engine, ruleFilter) -> [{ ruleName, reason, detail,
   factIds }] (RDAP1e). */
static napi_value f_refracted_activations(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    char *filter = NULL;
    if (!arg_rule_filter(env, argv[1], &filter))
        return NULL;
    js_list_t l = { env, NULL, 0 };
    napi_create_array(env, &l.arr);
    ds_result_t r = ds_engine_refracted_activations(je->e, filter, on_refract, &l);
    free(filter);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    return l.arr;
}

/* ── configuration ──────────────────────────────────────────────────────── */

/* A 0..2^32-1 count: a Number or a BigInt, as get_u64 takes them. */
static bool get_u32(napi_env env, napi_value v, uint32_t *out, const char *what) {
    uint64_t x = 0;
    if (!get_u64(env, v, &x, what))
        return false;
    if (x > UINT32_MAX) {
        char msg[128];
        snprintf(msg, sizeof msg, "%s: outside 0..2^32-1", what);
        napi_throw_range_error(env, NULL, msg);
        return false;
    }
    *out = (uint32_t) x;
    return true;
}

/* No hydration budget ([LHYD.7.4]), and no working-memory bound or pool
   sizing, which are realtime's ([NRTM.9.1]). */

/* setCacheCap(engine, capKeys, capBytes) — CACHEENG1 / [LCSP.2.2]; 0 = unbounded. */
static napi_value f_set_cache_cap(napi_env env, napi_callback_info info) {
    ARGS(3);
    ENGINE_ARG;
    uint32_t keys = 0;
    uint64_t bytes = 0;
    if (!get_u32(env, argv[1], &keys, "capKeys") || !get_u64(env, argv[2], &bytes, "capBytes"))
        return NULL;
    return finish(env, ds_engine_set_cache_cap(je->e, keys, bytes), NULL);
}

/* ── clone and the session header ───────────────────────────────────────── */

/* clone(engine) -> engine — ds_engine_clone ([NLFC.8]). libds starts the
   clone with no callbacks and no `user` pointer of the source's ([NLFC.8.3]),
   so its pump never reaches the source's JS. Only the clone's own
   stream handle is installed here. libds refuses a clone mid-pump or
   mid-callback, and of an engine in RT mode. */
static napi_value f_clone(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    ds_engine_t *dst = NULL;
    ds_result_t r = ds_engine_clone(je->e, &dst);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    js_engine_t *nj = calloc(1, sizeof *nj);
    if (nj == NULL) {
        ds_engine_free(dst);
        return throw_status(env, DS_ERR_OOM, "clone");
    }
    nj->e = dst;
    nj->env = env;
    r = ds_engine_set_stream_callback(dst, on_stream, nj);
    if (r.status != DS_OK) {
        napi_value err = make_ds_error(env, r.status, r.detail);
        ds_engine_free(dst);
        free(nj);
        napi_throw(env, err);
        return NULL;
    }
    snap_take(nj);      /* the clone holds the source's program */
    napi_value ext;
    napi_create_external(env, nj, engine_finalize, NULL, &ext);
    return ext;
}

/* sessionHeader(engine) -> { dsVersion, sessionId, tierId, dscHash }
   (LFST.4 / RFCS.4). dscHash is the loaded .dsc's SHA-256, or null before a
   load. */
static napi_value f_session_header(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    ds_session_header_t h;
    ds_result_t r = ds_engine_get_session_header(je->e, &h);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value o, hash;
    napi_create_object(env, &o);
    put_str(env, o, "dsVersion", h.ds_version);
    put_str(env, o, "sessionId", h.session_id);
    put_str(env, o, "tierId", h.tier_id);
    if (h.dsc_hash != NULL)         /* copied: see slot_to_js on emnapi */
        napi_create_buffer_copy(env, h.dsc_hash_len, (const void *) h.dsc_hash, NULL, &hash);
    else
        napi_get_null(env, &hash);
    napi_set_named_property(env, o, "dscHash", hash);
    return o;
}

/* runId(engine) / tierId(engine): the identity given at newEngine, or null
   when none was (`ds_engine_get_run_id`, `ds_engine_get_tier_id`). */
static napi_value engine_id(napi_env env, napi_callback_info info,
                            ds_result_t (*get)(const ds_engine_t *, const char **)) {
    ARGS(1);
    ENGINE_ARG;
    const char *s = NULL;
    ds_result_t r = get(je->e, &s);
    if (r.status != DS_OK)
        return throw_ds(env, r);
    napi_value out;
    if (s == NULL)
        napi_get_null(env, &out);
    else
        napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value f_run_id(napi_env env, napi_callback_info info) {
    return engine_id(env, info, ds_engine_get_run_id);
}

static napi_value f_tier_id(napi_env env, napi_callback_info info) {
    return engine_id(env, info, ds_engine_get_tier_id);
}

/* ── recording and replay ───────────────────────────────────────────────── */

/* The recorder's byte sink: each framed atom (and the header) to the JS sink,
   as a copy. A sink that throws is the recording failing, not the engine:
   the exception is taken off the stack, the first one kept for
   stopRecording's `cause`, and the recorder told DS_ERR_IO, which it latches
   in rec.last and stops on — pyds's short-write path. */
static ds_result_t rec_sink(const uint8_t *bytes, size_t len, void *user) {
    js_engine_t *je = user;
    napi_env env = je->env;
    napi_handle_scope scope;
    napi_value fn = NULL, undef, buf, res, err;
    bool pending = false;
    if (je->closing || je->rec_sink == NULL)
        return DS_ERR_R(DS_ERR_IO, "recording sink: gone");
    napi_is_exception_pending(env, &pending);
    if (pending)
        return DS_ERR_R(DS_ERR_IO, "recording sink: a JS exception is pending");
    napi_open_handle_scope(env, &scope);
    napi_get_reference_value(env, je->rec_sink, &fn);
    ds_result_t r = DS_OK_R;
    if (fn == NULL) {
        r = DS_ERR_R(DS_ERR_IO, "recording sink: collected");
    } else {
        static const uint8_t empty[1] = { 0 };
        napi_create_buffer_copy(env, len, len ? (const void *) bytes : (const void *) empty,
                                NULL, &buf);
        napi_get_undefined(env, &undef);
        /* A callback like any other: f_close refuses from inside it, since it
           runs inside the engine's own dispatch. */
        je->in_callback++;
        if (napi_call_function(env, undef, fn, 1, &buf, &res) != napi_ok) {
            napi_get_and_clear_last_exception(env, &err);
            if (je->rec_err == NULL && err != NULL)
                napi_create_reference(env, err, 1, &je->rec_err);
            r = DS_ERR_R(DS_ERR_IO, "recording sink threw");
        }
        je->in_callback--;
    }
    napi_close_handle_scope(env, scope);
    return r;
}

/* recordTo(engine, sink) — ds_rfcs_record_begin, chained through on_stream
   so the handle fence keeps its slot. The header and the schema
   announcements reach the sink at the engine's first stream event, or before
   this returns if the engine has already had one ([RFCS.5.1]). */
static napi_value f_record_to(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    napi_valuetype t;
    napi_typeof(env, argv[1], &t);
    if (t != napi_function)
        return throw_type(env, "recordTo: want a sink function");
    if (je->recording)
        return throw_status(env, DS_ERR_STATE, "recordTo: already recording; stopRecording first");
    je->recbuf = malloc(DS_JS_RECBUF);
    if (je->recbuf == NULL)
        return throw_status(env, DS_ERR_OOM, "recordTo");
    napi_create_reference(env, argv[1], 0, &je->rec_sink);
    ds_result_t r = ds_rfcs_record_begin(je->e, &je->rec, rec_sink, je, je->recbuf, DS_JS_RECBUF);
    if (r.status == DS_OK && je->rec.last.status != DS_OK)
        r = je->rec.last;           /* the sink refused the header, written now */
    if (r.status != DS_OK) {
        napi_value cause = NULL;
        if (je->rec_err != NULL)
            napi_get_reference_value(env, je->rec_err, &cause);
        napi_value err = make_ds_error(env, r.status, r.detail);
        if (cause != NULL)
            napi_set_named_property(env, err, "cause", cause);
        recording_release(env, je);
        napi_throw(env, err);
        return NULL;
    }
    je->recording = true;
    return NULL;
}

/* stopRecording(engine) — detach and report. Idempotent. The recorder's first
   error, if any, is thrown as a DsError, with the sink's own exception as
   `cause` when it was the sink that failed. */
static napi_value f_stop_recording(napi_env env, napi_callback_info info) {
    ARGS(1);
    ENGINE_ARG;
    if (!je->recording)
        return NULL;
    ds_result_t last = je->rec.last;
    napi_value err = NULL, cause = NULL;
    if (last.status != DS_OK) {
        err = make_ds_error(env, last.status, last.detail);
        if (je->rec_err != NULL && napi_get_reference_value(env, je->rec_err, &cause) == napi_ok
            && cause != NULL)
            napi_set_named_property(env, err, "cause", cause);
    }
    recording_release(env, je);
    if (err != NULL)
        napi_throw(env, err);
    return NULL;
}

static ds_result_t mark_in_wm(const ds_fact_t *f, void *user) {
    uint64_t id = 0;
    ds_result_t r = ds_fact_get_id(f, &id);
    if (r.status != DS_OK)
        return r;
    js_fact_t *jf = tab_find(user, f);
    if (jf != NULL && jf->id == id)     /* another id: a reused address */
        jf->in_wm = true;
    return DS_OK_R;
}

/* After a replay, on every path out of an open one, as pyds_after_replay.
   ds_rfcs_replay_begin put the replay's compare recorder
   in the stream slot and ds_rfcs_replay_finish left the slot empty, so
   on_stream goes back, or no listener, recording or fence hears anything more.
   The replay's events went to that recorder, so a fact that left working
   memory during it released no handle: the handles are checked against working
   memory here. A replayed fact with no handle needs nothing; wrap_fact makes
   one when it is first asked for.

   A running recording stays attached and resumes here. It hears no event of
   the replay, as pyds's does.

   A failed ds_rfcs_replay_begin does not come here: installing its recorder is
   the last thing that can fail, so the slot is still on_stream.

   A halted engine refuses both calls, so its slot stays empty: every call that
   could emit is refused too ([NCBK.2.9]), and teardown fires no event
   ([NLFC.6.4]). */
static void after_replay(js_engine_t *je) {
    if (ds_engine_set_stream_callback(je->e, on_stream, je).status != DS_OK
        || ds_engine_for_each_fact(je->e, NULL, mark_in_wm, je).status != DS_OK) {
        je->replay_halted = true;
        return;
    }
    for (size_t i = 0; i < je->cap; i++) {
        js_fact_t *jf = je->tab[i];
        if (jf == NULL || jf == TOMB)
            continue;
        if (!jf->in_wm)
            release_slot(je, &je->tab[i]);
        else
            jf->in_wm = false;
    }
}

static void replay_finalize(napi_env env, void *data, void *hint) {
    (void) env;
    (void) hint;
    js_replay_t *jr = data;
    if (jr->ctx != NULL) {          /* abandoned open: finish destroys it */
        ds_rfcs_replay_finish(jr->ctx, NULL);
        if (jr->je != NULL) {
            jr->je->replay = NULL;
            after_replay(jr->je);
        }
    }
    free(jr);
}

static js_replay_t *arg_replay(napi_env env, napi_value v) {
    void *p = NULL;
    if (napi_get_value_external(env, v, &p) != napi_ok || p == NULL) {
        throw_type(env, "not a replay handle");
        return NULL;
    }
    js_replay_t *jr = p;
    if (jr->ctx == NULL) {
        throw_status(env, DS_ERR_STATE, "the replay is finished, or its engine closed");
        return NULL;
    }
    return jr;
}

/* replayBegin(engine, maxAtomBytes) -> replay — ds_rfcs_replay_begin: the one
   replay operation, re-fire and compare ([LFST.9.6]). One open replay per
   engine. */
static napi_value f_replay_begin(napi_env env, napi_callback_info info) {
    ARGS(2);
    ENGINE_ARG;
    if (je->replay != NULL)
        return throw_status(env, DS_ERR_STATE, "a replay is already open on this engine");
    ds_rfcs_replay_opts_t opts;
    memset(&opts, 0, sizeof opts);
    if (!get_u32(env, argv[1], &opts.max_atom_bytes, "maxAtomBytes"))
        return NULL;
    js_replay_t *jr = calloc(1, sizeof *jr);
    if (jr == NULL)
        return throw_status(env, DS_ERR_OOM, "replay");
    ds_result_t r = ds_rfcs_replay_begin(je->e, &opts, &jr->ctx);
    if (r.status != DS_OK) {
        free(jr);
        return finish(env, r, NULL);
    }
    jr->je = je;
    je->replay = jr;
    napi_value ext;
    napi_create_external(env, jr, replay_finalize, NULL, &ext);
    return ext;
}

/* replayFeed(replay, chunk) — any boundaries; an atom may straddle chunks. */
static napi_value f_replay_feed(napi_env env, napi_callback_info info) {
    ARGS(2);
    js_replay_t *jr = arg_replay(env, argv[0]);
    if (jr == NULL)
        return NULL;
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[1], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[1], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "replayFeed: want a Uint8Array");
    return finish(env, ds_rfcs_replay_feed(jr->ctx, data, len), NULL);
}

/* replayFinish(replay) -> { asserts, retracts, clocks, ruleFires, calls,
   skipped, headerVerified } — destroys the ctx whatever it returns. */
static napi_value f_replay_finish(napi_env env, napi_callback_info info) {
    ARGS(1);
    js_replay_t *jr = arg_replay(env, argv[0]);
    if (jr == NULL)
        return NULL;
    ds_rfcs_replay_result_t out;
    memset(&out, 0, sizeof out);
    ds_result_t r = ds_rfcs_replay_finish(jr->ctx, &out);
    jr->ctx = NULL;
    if (jr->je != NULL) {
        jr->je->replay = NULL;
        after_replay(jr->je);
    }
    jr->je = NULL;
    if (r.status != DS_OK)
        return finish(env, r, NULL);
    napi_value o;
    napi_create_object(env, &o);
    put_u64(env, o, "asserts", out.asserts);
    put_u64(env, o, "retracts", out.retracts);
    put_u64(env, o, "clocks", out.clocks);
    put_u64(env, o, "ruleFires", out.rule_fires);
    put_u64(env, o, "calls", out.calls);
    put_u64(env, o, "withdrawals", out.withdrawals);
    put_u64(env, o, "skipped", out.skipped);
    put_bool(env, o, "headerVerified", out.header_verified);
    /* A partial trailing atom left unapplied ([RFCS.19.2]): the stream is
       still being written, or was cut. The chunked reader cannot tell; its
       caller can, and replayStream, which is handed the whole stream,
       refuses one. */
    put_u64(env, o, "tailBytes", out.tail_bytes);
    return finish(env, r, o);
}

/* ── reading atoms ──────────────────────────────────────────────────────── */
/*
 * NO CODEC HERE, as pyds's atoms.c says of itself: framing is
 * ds_rfcs_next_incremental and a body is ds_rfcs_visit_atom, both libds's, and
 * the glue only turns what they report into JS values. Both are in rfcs.h,
 * which the libds tarball ships, so the wasm target has them too.
 */

/* ds_rfcs_visit_atom's walk, built into nested JS objects. `stack[depth]` is
   the object fields at that depth go into. */
typedef struct {
    napi_env   env;
    napi_value stack[DS_RFCS_VISIT_MAX_DEPTH + 2];
    uint32_t   top;
    napi_value root;
    napi_value unknown;      /* the field numbers no descriptor named, in walk order */
    uint32_t   n_unknown;
    bool       failed;
} visit_ctx_t;

/* Put `v` under `name` in the current object; a repeated field (index >= 0)
   collects into an array. */
static void visit_put(visit_ctx_t *c, const ds_rfcs_field_t *f, napi_value v) {
    napi_value obj = c->stack[c->top];
    if (f->index < 0) {
        napi_set_named_property(c->env, obj, f->name, v);
        return;
    }
    napi_value arr;
    bool has = false;
    napi_has_named_property(c->env, obj, f->name, &has);
    if (has && f->index > 0) {
        napi_get_named_property(c->env, obj, f->name, &arr);
    } else {
        napi_create_array(c->env, &arr);
        napi_set_named_property(c->env, obj, f->name, arr);
    }
    napi_set_element(c->env, arr, (uint32_t) f->index, v);
}

static bool on_field(void *ctx, const ds_rfcs_field_t *f) {
    visit_ctx_t *c = ctx;
    napi_env env = c->env;
    napi_value v = NULL, n;
    switch (f->kind) {
    case DS_RFCS_FIELD_ENTER:
        napi_create_object(env, &v);
        if (f->depth == 0) {
            c->root = v;
            c->top = 0;
            c->stack[0] = v;
        } else {
            visit_put(c, f, v);
            if (c->top + 1 >= DS_RFCS_VISIT_MAX_DEPTH + 2) { c->failed = true; return false; }
            c->stack[++c->top] = v;
        }
        return true;
    case DS_RFCS_FIELD_LEAVE:
        if (f->depth > 0 && c->top > 0) c->top--;
        return true;
    case DS_RFCS_FIELD_INT:    napi_create_bigint_int64(env, f->v.i, &v); break;
    case DS_RFCS_FIELD_UINT:   napi_create_bigint_uint64(env, f->v.u, &v); break;
    case DS_RFCS_FIELD_DOUBLE: napi_create_double(env, f->v.d, &v); break;
    case DS_RFCS_FIELD_BOOL:   napi_get_boolean(env, f->v.b, &v); break;
    case DS_RFCS_FIELD_ENUM:
        /* The number and its name: a reader shows the name, and a number no
           name covers is still a value. */
        napi_create_object(env, &v);
        napi_create_int32(env, f->v.e.number, &n);
        napi_set_named_property(env, v, "number", n);
        if (f->v.e.name) napi_create_string_utf8(env, f->v.e.name, NAPI_AUTO_LENGTH, &n);
        else napi_get_null(env, &n);
        napi_set_named_property(env, v, "name", n);
        break;
    case DS_RFCS_FIELD_STRING:
        napi_create_string_utf8(env, (const char *) f->v.s.p, f->v.s.len, &v);
        break;
    case DS_RFCS_FIELD_BYTES: {
        /* Copied (buffer_copy, see slot_to_js on emnapi): borrowed for the
           call only. */
        static const uint8_t empty[1] = { 0 };
        napi_create_buffer_copy(env, f->v.s.len, f->v.s.len ? (const void *) f->v.s.p : (const void *) empty,
                                NULL, &v);
        break;
    }
    default:
        return true;
    }
    visit_put(c, f, v);
    return true;
}

/* A field no descriptor names, at any depth: its number, for the atom's
   `unknownFields` ([RTIM.14.9]). */
static bool on_unknown(void *ctx, const ds_rfcs_unknown_field_t *u) {
    visit_ctx_t *c = ctx;
    napi_value n;
    napi_create_uint32(c->env, u->number, &n);
    napi_set_element(c->env, c->unknown, c->n_unknown++, n);
    return true;
}

/* readAtoms(bytes, incremental) -> { atoms, end, incomplete, error }
 *
 * Every complete atom, in order: { offset, field, message, body,
 * unknownFields, bodyOffset, bodyLength }. An atom is named by its field
 * number ([RFCS.16.1]); `message` is the proto message (ds_rfcs_message_name),
 * and `body` the visited fields, or null for an atom the visitor has no
 * descriptor for. `unknownFields` is the number of each field in the body,
 * at any depth, that its message's descriptor does not name, in the order
 * read: empty when there are none, and when `body` is null. `bodyOffset` and
 * `bodyLength` give the body's bytes as framed, which a caller hands back to
 * libds (applyExternalAssert). Reading stops at the
 * end, at a partial trailing atom when `incremental` ([RFCS.19.2]: `end` is
 * where it starts and `incomplete` is true), or at bytes no append can repair:
 * then `error` is { offset, status, detail, field, message } and the atoms
 * before it are still returned, so a reader shows what it could read. `field`
 * and `message` name the atom when reading stopped at its body, so a reader
 * need not parse the frame to name it ([RTIM.14.15]), and are null when it
 * stopped at framing. Not incremental, a partial tail is such an error. */
static napi_value f_read_atoms(napi_env env, napi_callback_info info) {
    ARGS(2);
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false, incremental = false;
    napi_is_typedarray(env, argv[0], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[0], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "readAtoms: want a Uint8Array");
    if (argc > 1) napi_get_value_bool(env, argv[1], &incremental);

    ds_rfcs_reader_t rd;
    ds_rfcs_reader_init(&rd, data, len);
    napi_value out, atoms, err;
    napi_create_object(env, &out);
    napi_create_array(env, &atoms);
    napi_get_null(env, &err);
    uint32_t n = 0;
    bool incomplete = false;
    for (;;) {
        uint32_t field = 0;
        const uint8_t *body = NULL;
        size_t body_len = 0;
        ds_rfcs_step_t step = DS_RFCS_STEP_END;
        size_t at = rd.pos;
        ds_result_t r = ds_rfcs_next_incremental(&rd, &field, &body, &body_len, &step);
        if (r.status == DS_OK && step == DS_RFCS_STEP_INCOMPLETE && !incremental)
            r = DS_ERR_R(DS_ERR_PARSE, "a truncated atom at the end of the stream");
        if (r.status != DS_OK) {
            napi_create_object(env, &err);
            put_num(env, err, "offset", (double) rd.pos);
            put_num(env, err, "status", r.status);
            put_str(env, err, "detail", r.detail);
            put_null(env, err, "field");
            put_null(env, err, "message");
            break;
        }
        if (step == DS_RFCS_STEP_END) break;
        if (step == DS_RFCS_STEP_INCOMPLETE) { incomplete = true; break; }

        napi_value a;
        napi_create_object(env, &a);
        put_num(env, a, "offset", (double) at);
        put_num(env, a, "field", (double) field);
        const char *msg = ds_rfcs_message_name(field);
        put_str_or_null(env, a, "message", msg);
        visit_ctx_t c;
        memset(&c, 0, sizeof c);
        c.env = env;
        napi_create_array(env, &c.unknown);
        ds_result_t vr = ds_rfcs_visit_atom_with_unknown(field, body, body_len,
                                                         on_field, on_unknown, &c);
        napi_set_named_property(env, a, "unknownFields", c.unknown);
        if (vr.status == DS_ERR_NOT_FOUND) {
            put_null(env, a, "body");            /* no descriptor: the caller's band */
        } else if (vr.status != DS_OK || c.failed || c.root == NULL) {
            napi_create_object(env, &err);
            put_num(env, err, "offset", (double) at);
            put_num(env, err, "status", vr.status != DS_OK ? vr.status : DS_ERR_PARSE);
            put_str(env, err, "detail", vr.status != DS_OK ? vr.detail : "the body did not visit");
            put_num(env, err, "field", (double) field);
            put_str_or_null(env, err, "message", msg);
            break;
        } else {
            napi_set_named_property(env, a, "body", c.root);
        }
        put_num(env, a, "bodyOffset", (double) (body - (const uint8_t *) data));
        put_num(env, a, "bodyLength", (double) body_len);
        napi_set_element(env, atoms, n++, a);
    }
    napi_set_named_property(env, out, "atoms", atoms);
    put_num(env, out, "end", (double) rd.pos);
    put_bool(env, out, "incomplete", incomplete);
    napi_set_named_property(env, out, "error", err);
    return out;
}

/* messageName(field) -> "FactAssert" | null. bind.js has checked `field` is an
   integer in uint32's range; this checks it is a number at all. */
static napi_value f_message_name(napi_env env, napi_callback_info info) {
    ARGS(1);
    napi_valuetype type;
    uint32_t field = 0;
    napi_value out;
    if (napi_typeof(env, argv[0], &type) != napi_ok || type != napi_number
        || napi_get_value_uint32(env, argv[0], &field) != napi_ok)
        return throw_type(env, "messageName: want an atom's field number");
    const char *name = ds_rfcs_message_name(field);
    if (name == NULL) napi_get_null(env, &out);
    else napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &out);
    return out;
}

/* decodeFactBody(engine, schema, body) -> { slot: value, ... }
 * A FactAssert / FactEmit's typed fact body, by the engine's schema of that
 * name: ds_rfcs_decode_fact_body. Values as a fact's slots read (slot_to_js). */
static napi_value f_decode_fact_body(napi_env env, napi_callback_info info) {
    ARGS(3);
    ENGINE_ARG;
    char *name = get_string(env, argv[1]);
    if (name == NULL) return throw_type(env, "decodeFactBody: want a schema name");
    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_find(je->e, name, &schema);
    if (r.status == DS_OK && schema == NULL) {
        char msg[300];
        snprintf(msg, sizeof msg, "no schema named `%s` is registered with this engine", name);
        free(name);
        return throw_status(env, DS_ERR_SCHEMA_UNKNOWN, msg);
    }
    free(name);
    if (r.status != DS_OK) return throw_ds(env, r);
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[2], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[2], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array)
        return throw_type(env, "decodeFactBody: want a Uint8Array body");
    uint32_t n = 0, got = 0;
    ds_schema_get_slot_count(schema, &n);
    ds_slot_value_t *vals = calloc(n ? n : 1, sizeof *vals);
    char *scratch = malloc(len + n + 1);
    if (vals == NULL || scratch == NULL) {
        free(vals);
        free(scratch);
        return throw_status(env, DS_ERR_OOM, "decodeFactBody");
    }
    r = ds_rfcs_decode_fact_body(schema, data, len, vals, n, scratch, len + n + 1, &got);
    napi_value out = NULL;
    if (r.status == DS_OK) {
        napi_create_object(env, &out);
        for (uint32_t i = 0; i < got; i++) {
            ds_slot_desc_t d;
            ds_schema_get_slot(schema, i, &d);
            napi_value v = slot_to_js(env, je, &vals[i]);
            if (v == NULL) { out = NULL; break; }
            napi_set_named_property(env, out, d.name, v);
        }
    }
    for (uint32_t i = 0; i < got; i++)
        if (vals[i].kind == DS_SLOT_JSON && vals[i].v.json != NULL) ds_json_free(vals[i].v.json);
    free(vals);
    free(scratch);
    if (r.status != DS_OK) return throw_ds(env, r);
    return out;
}

/* `SlotKind`'s SLOT_KIND_SCHEMA (proto/slot.proto): a fact-ref slot. */
#define ANNOUNCED_KIND_SCHEMA 6u

/* The two announced decodes, one body of glue. `slots` is
 * [{ name, kind, nullable, schemaRef }], one per announced slot in declaration
 * order; bind.js has checked its shape. No engine, so no Fact can come out.
 *
 * decodeAnnouncedFactBody(slots, body) -> { slot: value, ... }:
 * ds_rfcs_decode_announced_fact_body, which refuses a fact-ref slot.
 *
 * decodeAnnouncedFactBodyHandles(slots, body) -> { slots, refs }:
 * ds_rfcs_decode_announced_fact_body_handles. `slots` holds every slot but a
 * fact-ref one, as the plain decode gives it; `refs` holds each fact-ref slot:
 * its recorded handle as a BigInt ([RFCS.6.3]: the fact_id of the record that
 * carried the referenced fact), or null where a nullable one is absent.
 *
 * Values as a fact's slots read (slot_to_js). */
static napi_value decode_announced(napi_env env, napi_callback_info info, bool with_handles) {
    const char *fn = with_handles ? "decodeAnnouncedFactBodyHandles" : "decodeAnnouncedFactBody";
    ARGS(2);
    bool is_array = false;
    uint32_t n = 0;
    if (napi_is_array(env, argv[0], &is_array) != napi_ok || !is_array
        || napi_get_array_length(env, argv[0], &n) != napi_ok) {
        char msg[120];
        snprintf(msg, sizeof msg, "%s: want an array of announced slots", fn);
        return throw_type(env, msg);
    }
    napi_typedarray_type t;
    size_t len = 0, off = 0;
    void *data = NULL;
    napi_value ab;
    bool is_ta = false;
    napi_is_typedarray(env, argv[1], &is_ta);
    if (!is_ta || napi_get_typedarray_info(env, argv[1], &t, &len, &data, &ab, &off) != napi_ok
        || t != napi_uint8_array) {
        char msg[120];
        snprintf(msg, sizeof msg, "%s: want a Uint8Array body", fn);
        return throw_type(env, msg);
    }
    ds_rfcs_announced_slot_t *slots = calloc(n ? n : 1, sizeof *slots);
    char **strs = calloc(n ? 2 * (size_t) n : 1, sizeof *strs);    /* each slot's name, schema_ref */
    ds_slot_value_t *vals = calloc(n ? n : 1, sizeof *vals);
    uint64_t *handles = with_handles ? calloc(n ? n : 1, sizeof *handles) : NULL;
    char *scratch = malloc(len + n + 1);
    napi_value out = NULL, values = NULL, refs = NULL;
    const char *bad = NULL;
    uint32_t got = 0;
    ds_result_t r;
    if (slots == NULL || strs == NULL || vals == NULL || scratch == NULL || (with_handles && handles == NULL)) {
        bad = "";
        throw_status(env, DS_ERR_OOM, fn);
        goto done;
    }
    /* A name, and a schemaRef, holding a lone surrogate is refused: a name
       becomes a key of the result, where it would come back as U+FFFD, and
       neither has UTF-8 (get_text). So is one holding U+0000, which libds would
       read cut short. A recording's announce holds neither. */
    for (uint32_t i = 0; i < n && bad == NULL; i++) {
        napi_value el, v;
        napi_valuetype vt;
        size_t len_unused = 0;
        bool lone = false;
        if (napi_get_element(env, argv[0], i, &el) != napi_ok
            || napi_get_named_property(env, el, "name", &v) != napi_ok
            || (strs[2 * i] = get_text(env, v, &len_unused, &lone)) == NULL) { bad = "a slot's name is not a string"; break; }
        if (lone) { bad = "a slot's name holds a lone surrogate"; break; }
        if (strlen(strs[2 * i]) != len_unused) { bad = "a slot's name holds U+0000"; break; }
        if (napi_get_named_property(env, el, "kind", &v) != napi_ok
            || napi_get_value_uint32(env, v, &slots[i].kind) != napi_ok) { bad = "a slot's kind is not a number"; break; }
        if (napi_get_named_property(env, el, "nullable", &v) != napi_ok
            || napi_get_value_bool(env, v, &slots[i].nullable) != napi_ok) { bad = "a slot's nullable is not a boolean"; break; }
        if (napi_get_named_property(env, el, "schemaRef", &v) == napi_ok && napi_typeof(env, v, &vt) == napi_ok
            && vt == napi_string && (strs[2 * i + 1] = get_text(env, v, &len_unused, &lone)) == NULL) goto done;      /* DS_ERR_OOM is pending */
        if (lone) { bad = "a slot's schemaRef holds a lone surrogate"; break; }
        if (strs[2 * i + 1] != NULL && strlen(strs[2 * i + 1]) != len_unused) { bad = "a slot's schemaRef holds U+0000"; break; }
        slots[i].name = strs[2 * i];
        slots[i].schema_ref = strs[2 * i + 1];
    }
    if (bad != NULL) {
        char msg[200];
        snprintf(msg, sizeof msg, "%s: %s", fn, bad);
        throw_type(env, msg);
        goto done;
    }
    r = with_handles
        ? ds_rfcs_decode_announced_fact_body_handles(slots, n, data, len, vals, handles, n, scratch,
                                                     len + n + 1, &got)
        : ds_rfcs_decode_announced_fact_body(slots, n, data, len, vals, n, scratch, len + n + 1, &got);
    if (r.status != DS_OK) {
        got = 0;        /* on an error libds leaves no Json allocated */
        throw_ds(env, r);
        goto done;
    }
    napi_create_object(env, &values);
    if (with_handles) napi_create_object(env, &refs);
    for (uint32_t i = 0; i < got; i++) {
        napi_value v;
        if (with_handles && slots[i].kind == ANNOUNCED_KIND_SCHEMA) {
            if (vals[i].kind == DS_SLOT_NULL) napi_get_null(env, &v);
            else napi_create_bigint_uint64(env, handles[i], &v);
            napi_set_named_property(env, refs, slots[i].name, v);
            continue;
        }
        v = slot_to_js(env, NULL, &vals[i]);
        if (v == NULL) goto done;               /* its exception is pending */
        napi_set_named_property(env, values, slots[i].name, v);
    }
    if (with_handles) {
        napi_create_object(env, &out);
        napi_set_named_property(env, out, "slots", values);
        napi_set_named_property(env, out, "refs", refs);
    } else {
        out = values;
    }
done:
    for (uint32_t i = 0; i < got; i++)
        if (vals[i].kind == DS_SLOT_JSON && vals[i].v.json != NULL) ds_json_free(vals[i].v.json);
    if (strs != NULL)
        for (size_t i = 0; i < 2 * (size_t) n; i++) free(strs[i]);
    free(strs);
    free(slots);
    free(vals);
    free(handles);
    free(scratch);
    return out;
}

static napi_value f_decode_announced_fact_body(napi_env env, napi_callback_info info) {
    return decode_announced(env, info, false);
}

static napi_value f_decode_announced_fact_body_handles(napi_env env, napi_callback_info info) {
    return decode_announced(env, info, true);
}

/* NO seriesValue: no public function reads a series ([NSBK.6.3]). */

/* NO registerSchema: a schema reaches the engine from a compiled artefact and
   in no other way ([NFCT.1.1]). */

static void instance_finalize(napi_env env, void *data, void *hint) {
    (void) hint;
    js_instance_t *inst = data;
    if (inst->error_ctor != NULL)
        napi_delete_reference(env, inst->error_ctor);
    if (inst->unraisable != NULL)
        napi_delete_reference(env, inst->unraisable);
    free(inst);
}

NAPI_MODULE_INIT() {
    js_instance_t *inst = calloc(1, sizeof *inst);
    if (inst == NULL
        || napi_set_instance_data(env, inst, instance_finalize, NULL) != napi_ok) {
        free(inst);
        napi_throw_error(env, NULL, "@ds-lang/ds: instance data");
        return NULL;
    }
#define FN(name, cb) { name, NULL, cb, NULL, NULL, NULL, napi_default, NULL }
    napi_property_descriptor d[] = {
        FN("init", f_init),
        FN("newEngine", f_new_engine),
        FN("close", f_close),
        FN("loadDsc", f_load_dsc),
        FN("schemaCount", f_schema_count),
        FN("schemaAt", f_schema_at),
        FN("slotConvert", f_slot_convert),
        FN("assert", f_assert),
        FN("assertExternal", f_assert_external),
        FN("applyExternalAssert", f_apply_external_assert),
        FN("retract", f_retract),
        FN("factId", f_fact_id),
        FN("factAlive", f_fact_alive),
        FN("factRead", f_fact_read),
        FN("facts", f_facts),
        FN("factCount", f_fact_count),
        FN("halted", f_halted),
        FN("factById", f_fact_by_id),
        FN("mem", f_mem),
        FN("pump", f_pump),
        FN("clockMode", f_clock_mode),
        FN("clockSetMode", f_clock_set_mode),
        FN("wallClockSet", f_wall_clock_set),
        FN("clockNow", f_clock_now),
        FN("clockNextDeadline", f_clock_next_deadline),
        FN("clockSet", f_clock_set),
        FN("clockAdvance", f_clock_advance),
        FN("platformSignature", f_platform_signature),
        FN("setCallback", f_set_callback),
        FN("setCacheCallbacks", f_set_cache_callbacks),
        FN("cacheSeed", f_cache_seed),
        FN("ruleMetaCount", f_rule_meta_count),
        FN("ruleMetaAt", f_rule_meta_at),
        FN("lineSpanCount", f_line_span_count),
        FN("lineSpanAt", f_line_span_at),
        FN("lineSpanFind", f_line_span_find),
        FN("getJustifiers", f_get_justifiers),
        FN("reteNetwork", f_rete_network),
        FN("reteMatchTrace", f_rete_match_trace),
        FN("refractedActivations", f_refracted_activations),
        FN("setCacheCap", f_set_cache_cap),
        FN("clone", f_clone),
        FN("sessionHeader", f_session_header),
        FN("runId", f_run_id),
        FN("tierId", f_tier_id),
        FN("recordTo", f_record_to),
        FN("stopRecording", f_stop_recording),
        FN("replayBegin", f_replay_begin),
        FN("replayFeed", f_replay_feed),
        FN("replayFinish", f_replay_finish),
        FN("readAtoms", f_read_atoms),
        FN("messageName", f_message_name),
        FN("decodeFactBody", f_decode_fact_body),
        FN("decodeAnnouncedFactBody", f_decode_announced_fact_body),
        FN("decodeAnnouncedFactBodyHandles", f_decode_announced_fact_body_handles),
    };
#undef FN
    napi_define_properties(env, exports, sizeof d / sizeof d[0], d);
    return exports;
}

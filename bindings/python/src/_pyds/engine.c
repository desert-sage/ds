/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * engine.c — pyds._pyds._Engine, the C half of pyds.Engine, wrapping
 * ds_engine_t *.
 *
 * W10 surface (ICOM.18.W10):
 *   - __new__ / __init__ — calls ds_engine_new with default config.
 *   - __dealloc__       — calls ds_engine_free.
 *   - close() / __enter__ / __exit__ — prompt deterministic teardown: frees
 *     the C engine and drops all held callbacks (idempotent). The type is
 *     GC-aware (tp_traverse / tp_clear / Py_TPFLAGS_HAVE_GC), so engine<->
 *     callback reference cycles are also collectable; close() just releases
 *     the C memory without waiting for the collector.
 *   - load_dsc(bytes)   — calls ds_engine_load_dsc.
 *
 * W11 (ICOM.18.W11) adds schema_count / schema_at / schema_find /
 * rule_meta_count / rule_meta_at / rule_meta_find as separate methods.
 */

#define _POSIX_C_SOURCE 200809L  /* strdup */
#include <errno.h>   /* RFCSXCODEC1 — fclose/fopen failure detail */
#include <stdio.h>   /* RFCSXCODEC1 — the recorder sink writes to a FILE* */
#include <string.h>

#include "pyds.h"

/* PYRFCS1 — ds_rfcs_replay for Engine.replay.
   RFCS lives in libds's internal tree, not runtime/include: it is not part of
   the integrator C ABI. pyds is a first-party binding built from this same
   source tree and already links libds.a (which archives rfcs_combined.o), so
   it can include it directly — the integrator-facing surface is the Python
   API, not this header. rfcs.h itself depends only on libds.h. */
#include "rfcs/rfcs.h"
#include "ds_names.h"  /* the enum names pyds and @ds-lang/ds share */

/* RFCSXCODEC1 — scratch the recorder assembles each atom into before handing
   it to the sink. It bounds the largest single atom, not the recording: the
   recorder streams (rfcs.h: "no whole-stream buffering"). 64 KiB matches
   build_unit's BU_RECBUF, the only other in-tree recorder, and leaves room for
   a fact body of String slots well past anything a test writes. */
#define PYDS_RECBUF (1u << 16)

/* `O&` converters for an unsigned argument at the width libds declares for it
   Anything with __index__ is accepted, as range() accepts it; a
   negative value, or one wider than the parameter, raises OverflowError. The
   K / k / I formats these replace masked to the C width instead, so -1 became
   2**64 - 1 and 2**32 + 5 became 5. */
static int
pyds_u64_arg(PyObject *obj, void *out)
{
    PyObject *index = PyNumber_Index(obj);
    if (index == NULL) return 0;
    unsigned long long v = PyLong_AsUnsignedLongLong(index);
    Py_DECREF(index);
    if (v == (unsigned long long)-1 && PyErr_Occurred()) return 0;
    *(uint64_t *)out = (uint64_t)v;
    return 1;
}

static int
pyds_u32_arg(PyObject *obj, void *out)
{
    uint64_t v = 0;
    if (!pyds_u64_arg(obj, &v)) return 0;
    if (v > UINT32_MAX) {
        PyErr_SetString(PyExc_OverflowError,
                        "int too large for a 32-bit unsigned argument");
        return 0;
    }
    *(uint32_t *)out = (uint32_t)v;
    return 1;
}

typedef struct {
    PyObject_HEAD
    ds_engine_t *engine;
    /* Strong references to the integrator-side callbacks the test
       harness has registered. NULL when unset. Each setter takes
       one Py_INCREF, swaps under the libds registration so an
       in-flight event never sees a freed PyObject, then drops the
       prior reference. dealloc clears all of them before
       ds_engine_free. */
    PyObject    *stream_cb;
    PyObject    *call_cb;
    PyObject    *cache_set_cb;
    PyObject    *cache_delete_cb;
    PyObject    *log_cb;
    PyObject    *metric_cb;
    /* No timezone resolver: zones resolve through `TimeZoneOffset` facts
       ([LTIM.10.7]), which a host asserts like any other. No sample and no
       series-declared callback: there is no samples plane. Nothing of a
       replay is retained: the engine copies a replayed fact's String and
       Bytes slots into its intern at assert. */
    /* The C recorder (ds_rfcs_record_to) behind
       pyds.Engine.record and pyds.Recording.close (_record_start and
       _record_stop). rfcs.h makes `rec` and its scratch buffer
       CALLER-owned and requires both to outlive recording, so they live on the
       engine object rather than a method frame. `recfile` non-NULL is the
       single source of truth for "recording is live".

       The engine's one stream slot holds pyds_on_event for the engine's
       whole life. It keeps the live-fact table, then hands each event
       to the recorder when one is armed (ds_rfcs_record_begin installs
       nothing) and to the Python stream callback when one is set. */
    ds_rfcs_recorder_t rec;
    uint8_t           *recbuf;
    FILE              *recfile;
    int                recflush;   /* fflush after every atom (record flush=) */
    /* THE LIVE-FACT TABLE: {fact_id: ds_fact_t * as an int}, every
       fact in working memory. It is the only way a Python value reaches a
       fact pointer: a fact is named by its id, an id with no entry is a
       KeyError, and nothing casts a Python int to a pointer. Fed by the
       engine's FACT_ASSERT / FACT_RETRACT events, which libds emits for every
       fact it announces before freeing it. Where it may not match working
       memory -- an insert that failed, a replay whose events went to the
       replay's own recorder, a clone -- it is rebuilt from
       ds_engine_for_each_fact before the call returns, because a lookup inside
       a callback cannot walk. `live_stale` marks a rebuild that has not
       happened yet, or failed; the next lookup retries it. */
    PyObject          *live;
    int                live_stale;
    /* The first exception a callback raised during the libds call in
       progress, and the callable that raised it (PYTHON_BINDING.md §2.3).
       `cb_settle` hands it on when the call returns, so both are NULL
       between calls. */
    PyObject          *cb_exc;
    PyObject          *cb_exc_from;
} PydsEngineObject;

static ds_result_t pyds_on_event(ds_engine_t *engine,
                                  const ds_stream_ev_t *ev, void *user);

/* ---- A callback's exception (PYTHON_BINDING.md §2.3) ------------------- */

/* `cb` raised, and the exception is set. libds carries on with the call and
   enters Python again, so the exception cannot stay set: the first of the
   call is kept for `cb_settle`, and a later one, which has nothing left to
   attach to, goes to sys.unraisablehook now. */
static void
cb_keep(PydsEngineObject *self, PyObject *cb)
{
    if (self->cb_exc != NULL) {
        PyErr_WriteUnraisable(cb);
        return;
    }
    self->cb_exc = PyErr_GetRaisedException();
    self->cb_exc_from = Py_NewRef(cb);
}

/* After a libds call that can run a callback, with its result. A failed call
   raises its pyds.Error with the kept exception as __cause__ (errors.c chains
   an exception set when it raises). A call that succeeded has no caller for
   the kept exception, so it goes to sys.unraisablehook, as sqlite3 reports a
   callback's. Returns 0 for DS_OK, else -1 with the error set. */
static int
cb_settle(PydsEngineObject *self, ds_result_t r)
{
    PyObject *exc = self->cb_exc;    /* owned */
    PyObject *from = self->cb_exc_from;
    self->cb_exc = NULL;
    self->cb_exc_from = NULL;
    if (r.status != DS_OK) {
        if (exc != NULL) {
            PyErr_SetRaisedException(exc);
        }
        Py_XDECREF(from);
        (void)pyds_raise_from_result(r);
        return -1;
    }
    if (exc != NULL) {
        PyErr_SetRaisedException(exc);
        PyErr_WriteUnraisable(from);
    }
    Py_XDECREF(from);
    return 0;
}

/* A kept exception whose libds call ended some other way: in a Python
   exception of the binding's own, which stays set, or in the engine's free.
   It is reported, not lost. */
static void
cb_drop(PydsEngineObject *self)
{
    if (self->cb_exc == NULL) {
        return;
    }
    PyObject *current = PyErr_GetRaisedException();
    PyObject *from = self->cb_exc_from;
    PyErr_SetRaisedException(self->cb_exc);
    self->cb_exc = NULL;
    self->cb_exc_from = NULL;
    PyErr_WriteUnraisable(from);
    Py_XDECREF(from);
    PyErr_SetRaisedException(current);
}

/* ---- Facts by id ------------------------------------------------------- */

/* pyds.facts.FactId, imported on first use: `pyds/__init__.py` imports this
   extension before `pyds.facts` exists. */
static PyObject *fact_id_type = NULL;

/* The name of `obj`'s type, for a message, as a new reference; NULL with an
   exception set. The extension builds against the 3.12 limited API (abi3,
   PY.16), where PyTypeObject is opaque and tp_name cannot be read, so the name
   comes through PyType_GetName. A built-in type's is what tp_name held: `int`,
   `str`. A message formats it with %U. */
static PyObject *
pyds_type_name(PyObject *obj)
{
    return PyType_GetName(Py_TYPE(obj));
}

/* A fact id as a pyds.FactId. */
static PyObject *
pyds_fact_id(uint64_t id)
{
    if (fact_id_type == NULL) {
        PyObject *mod = PyImport_ImportModule("pyds.facts");
        if (mod == NULL) return NULL;
        fact_id_type = PyObject_GetAttrString(mod, "FactId");
        Py_DECREF(mod);
        if (fact_id_type == NULL) return NULL;
    }
    PyObject *n = PyLong_FromUnsignedLongLong((unsigned long long)id);
    if (n == NULL) return NULL;
    PyObject *fid = PyObject_CallFunctionObjArgs(fact_id_type, n, NULL);
    Py_DECREF(n);
    return fid;
}

/* A live fact's id as a pyds.FactId. */
static PyObject *
pyds_fact_id_of(const ds_fact_t *fact)
{
    uint64_t id = 0;
    ds_result_t r = ds_fact_get_id(fact, &id);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    return pyds_fact_id(id);
}

/* Enter one fact. -1 with an exception set on failure. */
static int
pyds_live_put(PydsEngineObject *self, const ds_fact_t *fact)
{
    uint64_t id = 0;
    ds_result_t r = ds_fact_get_id(fact, &id);
    if (r.status != DS_OK) { (void)pyds_raise_from_result(r); return -1; }
    PyObject *key = PyLong_FromUnsignedLongLong((unsigned long long)id);
    PyObject *ptr = PyLong_FromVoidPtr((void *)fact);
    int rc = (key == NULL || ptr == NULL) ? -1
           : PyDict_SetItem(self->live, key, ptr);
    Py_XDECREF(key);
    Py_XDECREF(ptr);
    return rc;
}

static ds_result_t
pyds_live_visit(const ds_fact_t *fact, void *user)
{
    return pyds_live_put((PydsEngineObject *)user, fact) == 0
        ? DS_OK_R
        : DS_ERR_R(DS_ERR_OOM, "the live-fact table could not take a fact");
}

/* Rebuild the table from working memory. -1 with an exception set. */
static int
pyds_live_rebuild(PydsEngineObject *self)
{
    PyDict_Clear(self->live);
    ds_result_t r = ds_engine_for_each_fact(self->engine, NULL,
                                            pyds_live_visit, self);
    if (r.status != DS_OK) {
        if (!PyErr_Occurred()) (void)pyds_raise_from_result(r);
        self->live_stale = 1;
        return -1;
    }
    self->live_stale = 0;
    return 0;
}

/* Rebuild the table now, from outside any callback. Left to the next lookup,
   the rebuild could run inside one -- a stream callback reading engine.facts --
   where libds refuses the walk as re-entry. A rebuild that fails leaves the
   table stale for the next lookup to retry; an exception already pending is
   kept, and none is added. */
static void
pyds_live_refresh(PydsEngineObject *self)
{
    if (self->engine == NULL || self->live == NULL) return;
    PyObject *pending = PyErr_GetRaisedException();
    if (pyds_live_rebuild(self) < 0) PyErr_Clear();
    if (pending != NULL) PyErr_SetRaisedException(pending);
}

/* After a call that can change working memory: a table that is stale, or
   whose size is not the engine's fact count, missed something, and is
   rebuilt before the call returns. */
static void
pyds_live_check(PydsEngineObject *self)
{
    if (self->engine == NULL || self->live == NULL) return;
    size_t n = 0;
    if (self->live_stale
            || ds_engine_fact_count(self->engine, &n).status != DS_OK
            || (size_t)PyDict_Size(self->live) != n) {
        pyds_live_refresh(self);
    }
}

/* The live fact `obj` names. `obj` is a FactId, or anything with __index__
   but bool. NULL with KeyError when no live fact has that id -- retracted,
   expired, superseded, or never asserted -- and nothing is dereferenced. */
static ds_fact_t *
pyds_live_find(PydsEngineObject *self, PyObject *obj)
{
    if (PyBool_Check(obj) || !PyIndex_Check(obj)) {
        PyObject *tn = pyds_type_name(obj);
        if (tn != NULL) {
            PyErr_Format(PyExc_TypeError, "a fact is named by its FactId, not %U", tn);
            Py_DECREF(tn);
        }
        return NULL;
    }
    if (self->live_stale && pyds_live_rebuild(self) < 0) return NULL;
    PyObject *key = PyNumber_Index(obj);
    if (key == NULL) return NULL;
    PyObject *ptr = PyDict_GetItemWithError(self->live, key);   /* borrowed */
    if (ptr == NULL) {
        if (!PyErr_Occurred()) {
            PyObject *fid = PyObject_Repr(obj);
            if (fid != NULL) {
                PyErr_Format(PyExc_KeyError, "no live fact %U", fid);
                Py_DECREF(fid);
            }
        }
        Py_DECREF(key);
        return NULL;
    }
    Py_DECREF(key);
    return (ds_fact_t *)PyLong_AsVoidPtr(ptr);
}

/* _Engine(*, run_id=None, tier_id=None): the engine's identity, the
   integrator's to give ([NLFC.1.2]). `z` takes a str or None and refuses an
   embedded NUL with ValueError, which is what a C string needs. libds copies
   both at ds_engine_new, so the UTF-8 buffers need live only for the call,
   and it reads "" as absent. */
static int
PydsEngine_init(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = { "run_id", "tier_id", NULL };
    ds_engine_config_t config = { 0 };
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|$zz", kwlist,
                                     &config.run_id, &config.tier_id)) {
        return -1;
    }
    if (self->engine != NULL) {
        /* Already initialised; harmless second call. */
        return 0;
    }
    ds_result_t r = ds_engine_new(&config, &self->engine);
    if (r.status != DS_OK) {
        pyds_raise_from_result(r);
        return -1;
    }
    /* [NSBK.2.3] — NO REGISTRATION STEP. `ds_engine_new` registers the
       closed backend set itself, so pyds makes no call and links no internal
       symbol for it. */
    self->stream_cb       = NULL;
    self->call_cb         = NULL;
    self->cache_set_cb    = NULL;
    self->cache_delete_cb = NULL;
    self->log_cb          = NULL;
    self->metric_cb       = NULL;
    /* RFCSXCODEC1 — not recording. */
    memset(&self->rec, 0, sizeof(self->rec));
    self->recbuf          = NULL;
    self->recfile         = NULL;
    self->recflush        = 0;
    self->live            = PyDict_New();
    self->live_stale      = 0;
    if (self->live == NULL) return -1;
    r = ds_engine_set_stream_callback(self->engine, pyds_on_event, self);
    if (r.status != DS_OK) {
        pyds_raise_from_result(r);
        return -1;
    }
    return 0;
}

static ds_result_t pyds_stream_trampoline(ds_engine_t *engine,
                                           const ds_stream_ev_t *ev,
                                           void *user);

/* RFCSXCODEC1 — detach the C recorder and release what it borrowed. Returns
   the recorder's `last` result, the FIRST failure of the whole recording. A
   failure never aborts the engine; each one is also the status of the call
   that fired its event ([NCBK.1.5]), and this is the one answer for
   the stream as a whole. Idempotent; safe with a NULL engine. */
static ds_result_t
pyds_engine_stop_recording(PydsEngineObject *self, int *out_close_err)
{
    ds_result_t last = DS_OK_R;
    if (out_close_err) *out_close_err = 0;
    if (self->recfile == NULL) return last;

    /* Disarm FIRST: pyds_on_event reads `recfile` on every event, so with it
       NULL no event reaches the recorder while the file is closed. */
    FILE *f = self->recfile;
    self->recfile = NULL;
    last = self->rec.last;
    if (fclose(f) != 0 && out_close_err) *out_close_err = errno;
    PyMem_Free(self->recbuf);
    self->recbuf = NULL;
    memset(&self->rec, 0, sizeof(self->rec));
    self->recflush = 0;
    return last;
}

/* Drop every Python callback the engine holds: unregister it libds-side
   first while there is an engine (so no in-flight trampoline fires into a
   half-cleared object), then release the PyObject. This is the
   cycle-breaking step — an engine<->callback reference cycle (e.g. a stream
   callback bound to an object that holds the engine) is severed once these
   refs are gone. Shared by tp_clear (the GC breaking a cycle, engine still
   live) and teardown (engine already freed). Idempotent.

   ⚠ FROM tp_clear ON A HALTED ENGINE the unregistering is refused
   ([NCBK.2.9]) and the engine keeps pointers into what is released here.
   Nothing reaches them -- a halted engine refuses pump, and its free emits
   nothing -- and every trampoline checks its callable for NULL before use.
   Teardown does not have this gap because it frees the engine first. */
static void
pyds_engine_drop_callbacks(PydsEngineObject *self)
{
    /* RFCSXCODEC1 — the recorder is a stream callback too, and it is the one
       that holds an OS resource. Detach and close it before the engine goes,
       so a dropped engine cannot leave a half-written recording open. Its
       `last` is discarded here on purpose: teardown has no way to report an
       error, which is why Recording.close() exists as the checked path. */
    (void)pyds_engine_stop_recording(self, NULL);

    if (self->engine != NULL) {
        /* pyds's own observer is always installed. */
        ds_engine_set_stream_callback(self->engine, NULL, NULL);
        if (self->call_cb != NULL) {
            ds_engine_set_call_callback(self->engine, NULL, NULL);
        }
        if (self->cache_set_cb != NULL || self->cache_delete_cb != NULL) {
            ds_engine_cache_callbacks(self->engine, DS_CACHE_CB_ABI_VERSION, NULL, NULL, NULL);
        }
        if (self->log_cb != NULL) {
            ds_engine_set_log_callback(self->engine, NULL, NULL);
        }
        if (self->metric_cb != NULL) {
            ds_engine_set_metric_callback(self->engine, NULL, NULL);
        }
    }
    /* Py_CLEAR (NULL the field *before* DECREF) so a reentrant traverse
       during finalization never observes a dangling pointer. */
    Py_CLEAR(self->stream_cb);
    Py_CLEAR(self->call_cb);
    Py_CLEAR(self->cache_set_cb);
    Py_CLEAR(self->cache_delete_cb);
    Py_CLEAR(self->log_cb);
    Py_CLEAR(self->metric_cb);
    Py_CLEAR(self->live);           /* holds ints only */
}

/* Idempotent full teardown: free the C engine, THEN close the recording and
   release the callables and everything else `user` points at. Shared by
   close()/__exit__ (explicit, prompt) and dealloc (at refcount 0, or after
   the GC breaks a cycle). Safe to call repeatedly: afterwards engine is NULL
   and every method guards on that, raising ValueError("operation on a
   closed Engine"), as io does for a closed file.

   ⚠ THE ENGINE GOES FIRST. Unregistering the callbacks first does not
   work on a HALTED engine: every setter carries DS_ENGINE_REFUSE_IF_HALTED
   ([NCBK.2.9]), so the NULL-ing is refused and the engine would keep
   callbacks whose callables, and whose recording, had just been released.
   `ds_engine_free` stays valid on a halted engine, and [NLFC.6.4] already
   says to free the callback context after it returns. Once it has, nothing
   can call in: `pyds_engine_drop_callbacks` sees a NULL engine, skips every
   setter and the recorder's detach, and only closes and releases.

   ⚠ A REFUSED FREE CHANGES NOTHING. libds refuses to free an engine that is
   inside one of its own callbacks ([RARC.13.16]), and close() can be called
   from one. The refusal is returned with the engine, its callbacks and any
   recording untouched: dropping them would leak the engine, which carries on
   pumping, and close the recording under a recorder that stays installed.
   dealloc never meets it -- a method of this object is on the stack for as
   long as the engine is in a callback, so the object cannot be freed. */
static ds_result_t
pyds_engine_teardown(PydsEngineObject *self)
{
    if (self->engine != NULL) {
        ds_result_t r = ds_engine_free(self->engine);
        if (r.status != DS_OK) return r;
        self->engine = NULL;
    }
    pyds_engine_drop_callbacks(self);
    cb_drop(self);    /* a callback the free ran */
    return DS_OK_R;
}

/* GC protocol. The engine holds strong refs to its registered callbacks,
   which routinely reference the engine back (the normal way to consume
   streams / calls / caches), so engine<->callback reference cycles are
   easy to form. Implementing tp_traverse / tp_clear (+ Py_TPFLAGS_HAVE_GC
   on the type) lets the cyclic collector see the references the engine
   holds and break such a cycle even when the consumer never calls close().
   traverse MUST visit every PyObject the engine owns — omitting one lets
   the GC reclaim a still-referenced object (use-after-free). */
static int
PydsEngine_traverse(PydsEngineObject *self, visitproc visit, void *arg)
{
    /* A heap type's instance references its type, and the collector must see
       that reference too; a heap base visits it for its subclasses. */
    Py_VISIT(Py_TYPE((PyObject *)self));
    Py_VISIT(self->stream_cb);
    Py_VISIT(self->call_cb);
    Py_VISIT(self->cache_set_cb);
    Py_VISIT(self->cache_delete_cb);
    Py_VISIT(self->log_cb);
    Py_VISIT(self->metric_cb);
    Py_VISIT(self->live);
    Py_VISIT(self->cb_exc);        /* its traceback's frames may hold self */
    Py_VISIT(self->cb_exc_from);
    return 0;
}

static int
PydsEngine_clear(PydsEngineObject *self)
{
    /* Break the cycle by dropping the callback refs. The C engine is not a
       Python object (not part of the Python cycle); it is freed in dealloc.
       A kept exception is only held while one of this object's methods is on
       the stack, so nothing is kept when the collector reaches it; it is
       cleared, not reported, in case that ever stops holding. */
    pyds_engine_drop_callbacks(self);
    Py_CLEAR(self->cb_exc);
    Py_CLEAR(self->cb_exc_from);
    return 0;
}

/* tp_finalize (PEP 442). An engine collected unclosed is still freed, by
   dealloc, and a ResourceWarning names it, as an unclosed file or socket
   does (PY.4). It runs while the object is whole -- before dealloc, and
   before tp_clear when the collector breaks a cycle -- so its repr still
   works. A finalizer has no caller to raise to: a failure to warn goes to
   sys.unraisablehook, and any exception already set is kept. */
static void
PydsEngine_finalize(PydsEngineObject *self)
{
    if (self->engine == NULL) {
        return;
    }
    PyObject *exc = PyErr_GetRaisedException();
    if (PyErr_ResourceWarning((PyObject *)self, 1, "unclosed %R",
                              (PyObject *)self) < 0) {
        PyErr_WriteUnraisable((PyObject *)self);
    }
    PyErr_SetRaisedException(exc);
}

static void
PydsEngine_dealloc(PydsEngineObject *self)
{
    /* THE FINALIZER HAS RUN BY NOW, OR IS NOT RUN. Every engine an integrator
       holds is a pyds.Engine, a Python subclass, and CPython's subtype_dealloc
       runs tp_finalize before it calls this; the collector runs it before it
       frees any engine. Only a bare _Engine freed by its refcount arrives with
       it not run, and nothing outside pyds makes one (clone allocates
       Py_TYPE(self)). Its ResourceWarning is not given:
       PyObject_CallFinalizerFromDealloc, which would give it, is outside the
       3.12 limited API (PY.16), and calling the finalizer by hand here, at a
       refcount of 0, would hand a dead object to its repr. The engine is
       freed either way. test_unclosed_engine.py holds the warning for
       pyds.Engine.

       GC-tracked type: untrack before teardown so the collector never
       traverses a half-freed object. */
    PyObject_GC_UnTrack(self);
    (void)pyds_engine_teardown(self);
    /* A HEAP TYPE'S INSTANCE HOLDS A REFERENCE TO ITS TYPE, and its dealloc
       gives it back, a subclass's included: CPython's subtype_dealloc leaves
       that to a heap base. tp_free through the slot, as PyTypeObject is opaque
       under the limited API (PY.16). */
    PyTypeObject *tp = Py_TYPE((PyObject *)self);
    freefunc tp_free = (freefunc)PyType_GetSlot(tp, Py_tp_free);
    tp_free((PyObject *)self);
    Py_DECREF(tp);
}

/* close() / __enter__ / __exit__ — prompt, deterministic release of the C
   engine and the held callbacks. The type is GC-aware, so a cyclic engine
   is eventually collectable anyway, but close() frees the C engine (libds
   WM, tens of MB) at once rather than whenever the collector next runs.
   Idempotent; intended use is a context manager —
   `with pyds.Engine() as eng: ...` — for guaranteed per-scope release. */
static PyObject *
PydsEngine_close(PydsEngineObject *self, PyObject *Py_UNUSED(ignored))
{
    ds_result_t r = pyds_engine_teardown(self);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    Py_RETURN_NONE;
}

/* `closed`, as a file object's: true once close() has released the engine.
   Read-only, and it answers on a closed engine, which nothing else does. */
static PyObject *
PydsEngine_get_closed(PydsEngineObject *self, void *Py_UNUSED(closure))
{
    return PyBool_FromLong(self->engine == NULL);
}

static PyObject *
PydsEngine_enter(PydsEngineObject *self, PyObject *Py_UNUSED(ignored))
{
    return Py_NewRef((PyObject *)self);
}

static PyObject *
PydsEngine_exit(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    ds_result_t r = pyds_engine_teardown(self);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    Py_RETURN_FALSE;   /* do not suppress an exception from the with-body */
}

static PyObject *
PydsEngine_load_dsc(PydsEngineObject *self, PyObject *args)
{
    Py_buffer buf;
    if (!PyArg_ParseTuple(args, "y*", &buf)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyBuffer_Release(&buf);
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }

    ds_result_t r = ds_engine_load_dsc(
        self->engine,
        (const uint8_t *)buf.buf,
        (size_t)buf.len);
    PyBuffer_Release(&buf);
    pyds_live_check(self);

    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* The primitives behind pyds.Engine.schemas and .rules, which are Mappings
   (pyds/engine.py): a count, a record by position, a record by name. A
   position is that of libds's own order, and the view iterates in it. */

static int
pyds_index_arg(PyObject *arg, size_t *out)
{
    Py_ssize_t i = PyNumber_AsSsize_t(arg, PyExc_OverflowError);
    if (i == -1 && PyErr_Occurred()) {
        return -1;
    }
    if (i < 0) {
        PyErr_SetString(PyExc_IndexError, "negative index");
        return -1;
    }
    *out = (size_t)i;
    return 0;
}

static PyObject *
PydsEngine_schema_count(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    size_t count = 0;
    ds_result_t r = ds_engine_schema_count(self->engine, &count);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyLong_FromSize_t(count);
}

/* _set_admission(capability, admission, /): ds_engine_set_admission
   ([NLFC.10.2]). pyds.Engine.set_admission has checked both are members; a
   number wider than the C enum is refused here, and libds refuses one
   outside its registry with DS_ERR_INVAL. */
static PyObject *
PydsEngine_set_admission(PydsEngineObject *self, PyObject *args)
{
    uint32_t cap = 0;
    uint32_t admit = 0;
    if (!PyArg_ParseTuple(args, "O&O&:_set_admission",
                          pyds_u32_arg, &cap, pyds_u32_arg, &admit)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_set_admission(self->engine,
                                            (ds_capability_t)cap,
                                            (ds_admission_t)admit);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    Py_RETURN_NONE;
}

/* IndexError past the end, as a sequence's: libds reports NOT_FOUND. */
static PyObject *
PydsEngine_schema_at(PydsEngineObject *self, PyObject *arg)
{
    size_t index;
    if (pyds_index_arg(arg, &index) < 0) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_at(self->engine, index, &schema);
    if (r.status == DS_ERR_NOT_FOUND) {
        PyErr_SetString(PyExc_IndexError, "schema index out of range");
        return NULL;
    }
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return pyds_schema_record(schema);
}

/* None for a name the engine has no schema by. */
static PyObject *
PydsEngine_schema_find(PydsEngineObject *self, PyObject *arg)
{
    /* PyUnicode_AsUTF8 joins the limited API at 3.13; with no size asked for,
       this is the same call on 3.12. */
    const char *name = PyUnicode_AsUTF8AndSize(arg, NULL);
    if (name == NULL) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_find(self->engine, name, &schema);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    if (schema == NULL) {
        Py_RETURN_NONE;
    }
    return pyds_schema_record(schema);
}

/* The program's own source files ([RDSC.14.2]), behind pyds.Engine.sources:
   a count, and a record by position, (module_id, file, text). The text is the
   module's DS source, UTF-8 with its length given. */
static PyObject *
PydsEngine_ds_source_count(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    size_t count = 0;
    ds_result_t r = ds_engine_ds_source_count(self->engine, &count);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyLong_FromSize_t(count);
}

/* IndexError past the end, as a sequence's: libds reports NOT_FOUND. */
static PyObject *
PydsEngine_ds_source_at(PydsEngineObject *self, PyObject *arg)
{
    size_t index;
    if (pyds_index_arg(arg, &index) < 0) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_ds_source_view_t view = { 0 };
    ds_result_t r = ds_engine_ds_source_at(self->engine, index, &view);
    if (r.status == DS_ERR_NOT_FOUND) {
        PyErr_SetString(PyExc_IndexError, "source index out of range");
        return NULL;
    }
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    /* Owned; the N below hands it to the tuple. */
    PyObject *text = PyUnicode_DecodeUTF8(view.text,
                                          (Py_ssize_t)view.text_len,
                                          "strict");
    if (text == NULL) {
        return NULL;
    }
    return Py_BuildValue("(IsN)", (unsigned int)view.module_id, view.file,
                         text);
}

/* Rete node to source position ([RDSC.14.3]), behind
   pyds.Engine.line_spans: (node_id, module_id, file, line, column). */
static PyObject *
PydsEngine_line_span_record(const ds_line_span_view_t *view)
{
    return Py_BuildValue("(IIsII)", (unsigned int)view->node_id,
                         (unsigned int)view->module_id, view->ds_file,
                         (unsigned int)view->ds_line,
                         (unsigned int)view->ds_col);
}

static PyObject *
PydsEngine_line_span_count(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    size_t count = 0;
    ds_result_t r = ds_engine_line_span_count(self->engine, &count);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyLong_FromSize_t(count);
}

/* IndexError past the end, as a sequence's: libds reports NOT_FOUND. */
static PyObject *
PydsEngine_line_span_at(PydsEngineObject *self, PyObject *arg)
{
    size_t index;
    if (pyds_index_arg(arg, &index) < 0) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_line_span_view_t view = { 0 };
    ds_result_t r = ds_engine_line_span_at(self->engine, index, &view);
    if (r.status == DS_ERR_NOT_FOUND) {
        PyErr_SetString(PyExc_IndexError, "line span index out of range");
        return NULL;
    }
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PydsEngine_line_span_record(&view);
}

/* None for a node no span maps: libds reports NOT_FOUND. */
static PyObject *
PydsEngine_line_span_find(PydsEngineObject *self, PyObject *arg)
{
    uint32_t node_id = 0;
    if (!pyds_u32_arg(arg, &node_id)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_line_span_view_t view = { 0 };
    ds_result_t r = ds_engine_line_span_find(self->engine, node_id, &view);
    if (r.status == DS_ERR_NOT_FOUND) {
        Py_RETURN_NONE;
    }
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PydsEngine_line_span_record(&view);
}

static PyObject *
PydsEngine_rule_count(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    size_t count = 0;
    ds_result_t r = ds_engine_rule_meta_count(self->engine, &count);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyLong_FromSize_t(count);
}

static PyObject *
PydsEngine_rule_at(PydsEngineObject *self, PyObject *arg)
{
    size_t index;
    if (pyds_index_arg(arg, &index) < 0) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_rule_meta_view_t view;
    ds_result_t r = ds_engine_rule_meta_at(self->engine, index, &view);
    if (r.status == DS_ERR_NOT_FOUND) {
        PyErr_SetString(PyExc_IndexError, "rule index out of range");
        return NULL;
    }
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return pyds_rule_record(&view);
}

static PyObject *
PydsEngine_rule_find(PydsEngineObject *self, PyObject *arg)
{
    const char *name = PyUnicode_AsUTF8AndSize(arg, NULL);   /* see schema_find */
    if (name == NULL) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_rule_meta_view_t view;
    bool found = false;
    ds_result_t r = ds_engine_rule_meta_find(self->engine, name, &view,
                                             &found);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    if (!found) {
        Py_RETURN_NONE;
    }
    return pyds_rule_record(&view);
}

/* Recursively convert a Python value into a ds_json_t tree. On
   failure sets a Python exception and returns NULL. Caller owns
   the tree; release via ds_json_free.

   Mapping:
     None       → DS_JSON_NULL
     True/False → DS_JSON_BOOL
     int        → DS_JSON_INT
     float      → DS_JSON_FLOAT
     str        → DS_JSON_STRING (heap-copied)
     list/tuple → DS_JSON_ARRAY  (recursed)
     dict       → DS_JSON_OBJECT (keys must be str, recursed)

   Other types reject with TypeError. */
/* A builder's refusal as a Python exception: MemoryError for an allocation
   failure, and libds's own status for anything else -- a value over one of
   the Json limits is DS_ERR_JSON_LIMIT, a property of the value, not
   of the heap. */
static void
pyds_json_build_error(ds_result_t r)
{
    if (r.status == DS_ERR_OOM) {
        PyErr_NoMemory();
        return;
    }
    (void)pyds_raise_from_result(r);
}

static ds_json_t *
pyds_py_to_json_tree_at(PyObject *py, int level)
{
    /* Built entirely through the public ds_json builder API (no field-writes):
       ds_json is opaque. new_* yields an owned node; array_append / object_set
       take the child on success and leave it unconsumed on error, so an error
       frees the pending child before unwinding. */
    ds_json_t  *node = NULL;
    ds_result_t r;

    /* THE DEPTH LIMIT, BEFORE THE RECURSION. libds's builders
       refuse a tree deeper than DS_JSON_MAX_DEPTH, but this walk descends the
       PYTHON value first and builds on the way back up, so a list nested a
       million deep would overflow the C stack here long before libds saw a
       node. Refused here with the status libds gives the same value; `level`
       counts as libds's depth does (the root is 1). */
    if (level > DS_JSON_MAX_DEPTH) {
        pyds_json_build_error((ds_result_t){
            DS_ERR_JSON_LIMIT, "Json value nested deeper than DS_JSON_MAX_DEPTH" });
        return NULL;
    }

    if (py == Py_None) {
        r = ds_json_new_null(&node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        return node;
    }
    /* Bool check before int because PyBool_Check is a subclass of long. */
    if (PyBool_Check(py)) {
        r = ds_json_new_bool(py == Py_True, &node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        return node;
    }
    if (PyLong_Check(py)) {
        long long v = PyLong_AsLongLong(py);
        if (v == -1 && PyErr_Occurred()) return NULL;
        r = ds_json_new_int((int64_t)v, &node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        return node;
    }
    if (PyFloat_Check(py)) {
        double v = PyFloat_AsDouble(py);
        if (v == -1.0 && PyErr_Occurred()) return NULL;
        r = ds_json_new_float(v, &node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        return node;
    }
    if (PyUnicode_Check(py)) {
        Py_ssize_t  slen = 0;
        const char *s = PyUnicode_AsUTF8AndSize(py, &slen);
        if (s == NULL) return NULL;
        /* A Json string holds no U+0000 (LSTR.1.1). libds refuses one too,
           but as a status; a NUL in a str is the caller's value, so it is
           the ValueError Python gives an embedded NUL, raised before the
           call, as for a String slot (LSTR.1.5). */
        if (strlen(s) != (size_t)slen) {
            PyErr_SetString(PyExc_ValueError,
                "Json string: embedded null character: a String holds no "
                "U+0000");
            return NULL;
        }
        r = ds_json_new_string(s, (size_t)slen, &node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        return node;
    }
    if (PyList_Check(py) || PyTuple_Check(py)) {
        Py_ssize_t n = PySequence_Size(py);
        if (n < 0) return NULL;
        r = ds_json_new_array(&node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        for (Py_ssize_t i = 0; i < n; i++) {
            PyObject *item = PySequence_GetItem(py, i);  /* new ref */
            if (item == NULL) { ds_json_free(node); return NULL; }
            ds_json_t *child = pyds_py_to_json_tree_at(item, level + 1);
            Py_DECREF(item);
            if (child == NULL) { ds_json_free(node); return NULL; }
            r = ds_json_array_append(node, child);
            if (r.status != DS_OK) {
                ds_json_free(child);   /* not consumed on error */
                ds_json_free(node);
                pyds_json_build_error(r);
                return NULL;
            }
        }
        return node;
    }
    if (PyDict_Check(py)) {
        r = ds_json_new_object(&node);
        if (r.status != DS_OK) { pyds_json_build_error(r); return NULL; }
        Py_ssize_t pos = 0;
        PyObject *k, *v;
        while (PyDict_Next(py, &pos, &k, &v)) {
            if (!PyUnicode_Check(k)) {
                PyObject *tn = pyds_type_name(k);
                if (tn != NULL) {
                    PyErr_Format(PyExc_TypeError,
                        "JSON dict keys must be str, got %U", tn);
                    Py_DECREF(tn);
                }
                ds_json_free(node);
                return NULL;
            }
            Py_ssize_t  klen = 0;
            const char *ks = PyUnicode_AsUTF8AndSize(k, &klen);
            if (ks == NULL) { ds_json_free(node); return NULL; }
            if (strlen(ks) != (size_t)klen) {
                PyErr_SetString(PyExc_ValueError,
                    "Json object key: embedded null character: a String "
                    "holds no U+0000");
                ds_json_free(node);
                return NULL;
            }
            ds_json_t *child = pyds_py_to_json_tree_at(v, level + 1);
            if (child == NULL) { ds_json_free(node); return NULL; }
            r = ds_json_object_set(node, ks, (size_t)klen, child);
            if (r.status != DS_OK) {
                ds_json_free(child);   /* not consumed on error */
                ds_json_free(node);
                pyds_json_build_error(r);
                return NULL;
            }
        }
        return node;
    }
    PyObject *tn = pyds_type_name(py);
    if (tn != NULL) {
        PyErr_Format(PyExc_TypeError,
            "cannot convert %U to JSON (need None / bool / int / float "
            "/ str / list / tuple / dict)", tn);
        Py_DECREF(tn);
    }
    return NULL;
}

static ds_json_t *
pyds_py_to_json_tree(PyObject *py)
{
    return pyds_py_to_json_tree_at(py, 1);
}

/* TypeError "slot `NAME`: expected WANT, got TYPE", and -1. */
static int
pyds_slot_type_error(const char *slot_name, const char *want, PyObject *got)
{
    PyObject *tn = pyds_type_name(got);
    if (tn != NULL) {
        PyErr_Format(PyExc_TypeError, "slot `%s`: expected %s, got %U",
                     slot_name, want, tn);
        Py_DECREF(tn);
    }
    return -1;
}

/* Coerce a Python value into a ds_slot_value_t per the slot's
   declared type. Returns 0 on success; on failure sets a Python
   exception and returns -1.

   A fact-ref slot's target is found in `self`'s live-fact table. */
static int
pyds_value_for_slot(PydsEngineObject *self,
                     const char       *slot_name,
                     ds_slot_type_t    slot_type,
                     PyObject         *py_value,
                     ds_slot_value_t  *out)
{
    /* [LNUL.2.1] / [LNUL.3.1] — a Python `None` maps to the canonical DS null
       regardless of the declared slot type; the runtime admits it only in a
       nullable slot and rejects it elsewhere (wm_validate_assert_values).

       There is exactly ONE null ([LNUL.2.1]), so this holds for a `Json?` slot
       too: `None` is the canonical null there. A Json document whose root is
       `null` is the same value ([LNUL.3.4]), and libds stores one handed to a
       `Json?` slot as this null and refuses one for a `Json` slot, so passing
       DS_SLOT_NULL straight away is what libds would make of it anyway. */
    if (py_value == Py_None) {
        out->kind = DS_SLOT_NULL;
        return 0;
    }
    switch (slot_type) {
    case DS_SLOT_TYPE_INT:
    /* RDSC.5.5.8: Time, Date and Duration are Int-represented: their value
       crosses as an Int's does. Only the declared type differs. */
    case DS_SLOT_TYPE_TIME:
    case DS_SLOT_TYPE_DATE:
    case DS_SLOT_TYPE_DURATION: {
        /* An integer and nothing else: an int, or anything
           with __index__, the conversion range() and slicing use. A bool is
           refused although it is an int, so a Bool-shaped value cannot pass
           for a count. A float is refused rather than converted: a C cast
           from a double is undefined for NaN, the infinities and anything
           outside int64, and truncates everything else. An author holding a
           float converts it, and decides how. */
        if (PyBool_Check(py_value) || !PyIndex_Check(py_value)) {
            return pyds_slot_type_error(slot_name, "int", py_value);
        }
        PyObject *index = PyNumber_Index(py_value);
        if (index == NULL) return -1;
        long long v = PyLong_AsLongLong(index);   /* OverflowError past int64 */
        Py_DECREF(index);
        if (v == -1 && PyErr_Occurred()) return -1;
        out->kind = DS_SLOT_INT;
        out->v.i  = (int64_t)v;
        return 0;
    }
    case DS_SLOT_TYPE_FLOAT: {
        /* A float and nothing else: an int is refused too, though Python's
           typing would take one here, because NFCT.2.3 admits no implicit
           conversion and an int above 2**53 does not survive it. */
        if (!PyFloat_Check(py_value)) {
            return pyds_slot_type_error(slot_name, "float", py_value);
        }
        double v = PyFloat_AsDouble(py_value);
        if (v == -1.0 && PyErr_Occurred()) return -1;
        out->kind = DS_SLOT_FLOAT;
        out->v.f  = v;
        return 0;
    }
    case DS_SLOT_TYPE_STRING: {
        /* A `str`, or `bytes` / `bytearray` as the text's UTF-8 octets.
           The octets cross UNCHANGED: no decode, no repair, no check here.
           Whether they are well-formed UTF-8 is libds's to judge, and it
           refuses ill-formed text with DS_ERR_ENCODING ([LSTR.8.5]), raised as
           pyds.Error with Status.ENCODING. A `str` cannot carry such octets
           (PyUnicode_AsUTF8AndSize refuses a lone surrogate), so without
           `bytes` that refusal was unreachable through pyds, and a vector
           could test pyds there but not the engine.
           Both buffers end in a NUL CPython keeps past their length, so either
           is a C string for as long as the caller holds the object, which
           spans the assert. */
        Py_ssize_t  slen = 0;
        const char *s = NULL;
        if (PyUnicode_Check(py_value)) {
            s = PyUnicode_AsUTF8AndSize(py_value, &slen);
            if (s == NULL) return -1;  /* PyUnicode_AsUTF8AndSize sets exc */
        } else if (PyBytes_Check(py_value)) {
            if (PyBytes_AsStringAndSize(py_value, (char **)&s, &slen) < 0)
                return -1;  /* exc set */
        } else if (PyByteArray_Check(py_value)) {
            s    = PyByteArray_AsString(py_value);
            slen = PyByteArray_Size(py_value);
            if (s == NULL) return -1;
        } else {
            return pyds_slot_type_error(slot_name, "str or bytes", py_value);
        }
        /* A String holds no U+0000 (LSTR.1.1). libds takes a C string, which
           a NUL would cut short, so the refusal is here, before the call
           (LSTR.1.5), and is the ValueError Python gives an embedded NUL --
           for octets as for a str, since a 0x00 octet is U+0000 in UTF-8. */
        if (strlen(s) != (size_t)slen) {
            PyErr_Format(PyExc_ValueError,
                "slot `%s`: embedded null character: a String holds no U+0000",
                slot_name);
            return -1;
        }
        out->kind = DS_SLOT_STRING;
        out->v.s  = s;
        return 0;
    }
    case DS_SLOT_TYPE_BOOL: {
        if (!PyBool_Check(py_value)) {
            return pyds_slot_type_error(slot_name, "bool", py_value);
        }
        out->kind = DS_SLOT_BOOL;
        out->v.b  = (py_value == Py_True);
        return 0;
    }
    case DS_SLOT_TYPE_JSON: {
        /* Recursively convert a Python value (dict / list / str /
           int / float / bool / None) into a ds_json_t tree. The
           tree is owned here for the duration of the assert and
           freed by ds_engine_assert internally; we set kind=JSON
           and v.json on the slot value. */
        ds_json_t *tree = pyds_py_to_json_tree(py_value);
        if (tree == NULL) return -1;  /* exception set */
        out->kind   = DS_SLOT_JSON;
        out->v.json = tree;
        return 0;
    }
    case DS_SLOT_TYPE_BYTES: {
        /* LFAC.4 / LEXP — Bytes-typed slot. Accept Python
           `bytes` or `bytearray`; the value is borrowed for the
           duration of the assert. CLIPS stores Bytes as a
           length-tagged STRING under the hood, so we route via
           the DS_SLOT_BYTES kind which the engine then converts
           to the same CLIPS string slot the dispatcher reads. */
        const char *buf = NULL;
        Py_ssize_t  len = 0;
        if (PyBytes_Check(py_value)) {
            if (PyBytes_AsStringAndSize(py_value,
                    (char **)&buf, &len) < 0) {
                return -1;  /* exc set */
            }
        } else if (PyByteArray_Check(py_value)) {
            buf = PyByteArray_AsString(py_value);
            len = PyByteArray_Size(py_value);
            if (buf == NULL && len > 0) return -1;
        } else {
            return pyds_slot_type_error(slot_name, "bytes / bytearray", py_value);
        }
        out->kind = DS_SLOT_BYTES;
        out->v.bytes.data = (const uint8_t *) buf;
        out->v.bytes.len  = (size_t) len;
        return 0;
    }
    case DS_SLOT_TYPE_SCHEMA: {
        /* A fact-ref slot takes the target's FactId, found in the live-fact
           table: a target that is not live is a KeyError, never a
           pointer made from an int. The dispatcher checks the target's schema
           against the slot's declared one; libds keeps the target's id, not
           the pointer, which is a borrow for this call ([NFCT.2.4]). */
        ds_fact_t *target = pyds_live_find(self, py_value);
        if (target == NULL) return -1;
        out->kind  = DS_SLOT_FACT_REF;
        out->v.ref = target;
        return 0;
    }
    default:
        PyErr_Format(PyExc_NotImplementedError,
            "slot `%s`: unrecognised slot type %d",
            slot_name, (int)slot_type);
        return -1;
    }
}

/* HYDRT1a — build the ds_slot_value_t array from kwargs, for assert_.
   Every declared slot must be supplied by a
   matching kwarg, EXCEPT the auto-injected `hydrated_corr` slot, which is
   optional and defaults to "" (a live fact). Every supplied kwarg must
   match some slot (so a typo still errors, as the old strict slot/kwarg
   count check did). On success returns 0 and sets *out_values (PyMem-
   allocated; caller frees); on failure returns -1 with an exception set. */
/* Free a slot array and the Json trees in it. The trees are the
   caller's until the assert has serialised them, so every path out of an
   assert -- a refused slot included -- releases the ones built so far. The
   array is calloc'd, so a slot not yet built is not a Json one. */
static void
pyds_free_slot_values(ds_slot_value_t *values, uint32_t n_slots)
{
    if (values == NULL) return;
    for (uint32_t i = 0; i < n_slots; i++) {
        if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL) {
            ds_json_free(values[i].v.json);
        }
    }
    PyMem_Free(values);
}

static int
pyds_build_slot_values(PydsEngineObject  *self,
                        const ds_schema_t *schema,
                        const char        *schema_name,
                        uint32_t           n_slots,
                        PyObject          *kwds,
                        ds_slot_value_t  **out_values)
{
    *out_values = NULL;
    ds_slot_value_t *values = NULL;
    if (n_slots > 0) {
        values = PyMem_Calloc(n_slots, sizeof(*values));
        if (values == NULL) { PyErr_NoMemory(); return -1; }
    }

    Py_ssize_t n_kwargs       = (kwds != NULL) ? PyDict_Size(kwds) : 0;
    uint32_t   matched_kwargs = 0;

    for (uint32_t i = 0; i < n_slots; i++) {
        ds_slot_desc_t desc;
        ds_result_t r = ds_schema_get_slot(schema, i, &desc);
        if (r.status != DS_OK) {
            pyds_free_slot_values(values, n_slots);
            (void)pyds_raise_from_result(r);
            return -1;
        }
        PyObject *py_v = (kwds != NULL)
            ? PyDict_GetItemString(kwds, desc.name)  /* borrowed */
            : NULL;
        if (py_v == NULL && strcmp(desc.name, "hydrated_corr") == 0) {
            /* Optional auto-injected slot -> "" (a live fact). The static
               literal is valid for the duration of the assert, so there is
               no PyObject lifetime to manage (cf. pyds_value_for_slot,
               which borrows PyUnicode_AsUTF8). */
            values[i].kind = DS_SLOT_STRING;
            values[i].v.s  = "";
            continue;
        }
        if (py_v == NULL && desc.nullable) {
            /* OMISSION IS NULL, for a nullable slot only ([LNUL.4.1]). That
               clause states the semantics in terms of absence — "with
               `s.state` absent, `s.state + 1` ... evaluate to null" — so a
               fact whose `T?` slot was never given a value is the ordinary way
               to reach the null paths, not an edge case.
               `wm_validate_assert_values` already says what to send:
               "assert DS_SLOT_NULL for a nullable slot" (wm.c). The kind
               exists ([LNUL.9.1]) and the descriptor carries `nullable`
               ([RDSC.7.1]); this binding was the only layer with no way to
               express it.
               NULLABLE ONLY, and that is the whole guard. An omitted
               NON-nullable slot is still a TypeError below: passing
               DS_SLOT_NULL there is rejected by the same validator
               ([LNUL.3.4]), so accepting the omission here would only move a
               clear "you forgot a slot" into a refusal from two layers down.
               LCST.4.3.4.a_* and IRET.9.6.a_* assert a nullable slot by
               omission. */
            values[i].kind = DS_SLOT_NULL;
            continue;
        }
        if (py_v == NULL) {
            PyErr_Format(PyExc_TypeError,
                "schema `%s`: missing kwarg for slot `%s`",
                schema_name, desc.name);
            pyds_free_slot_values(values, n_slots);
            return -1;
        }
        matched_kwargs++;
        if (pyds_value_for_slot(self, desc.name, desc.type, py_v,
                                  &values[i]) != 0) {
            pyds_free_slot_values(values, n_slots);
            return -1;
        }
    }

    if ((Py_ssize_t)matched_kwargs != n_kwargs) {
        PyErr_Format(PyExc_TypeError,
            "schema `%s`: got %zd kwargs but %u matched slots "
            "(unknown slot name?)",
            schema_name, n_kwargs, (unsigned)matched_kwargs);
        pyds_free_slot_values(values, n_slots);
        return -1;
    }

    *out_values = values;
    return 0;
}

static PyObject *
PydsEngine_assert_(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    /* Signature: assert_(schema_name, **slot_values). The trailing
       underscore is because `assert` is a Python keyword. Slot
       values are passed as kwargs (slot-name → value); they're
       reordered into schema-declaration order before calling
       ds_engine_assert. */
    const char *schema_name;
    static char *kwlist[] = { "schema_name", NULL };
    /* `|`-suffix split: positional arg first, then we read slots
       from `kwds` ourselves so we can give per-kwarg errors. */
    if (!PyArg_ParseTupleAndKeywords(args, NULL, "s", kwlist,
                                      &schema_name)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }

    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_find(self->engine, schema_name, &schema);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    if (schema == NULL) {
        PyErr_Format(PyExc_KeyError,
            "no schema named `%s` registered with this engine",
            schema_name);
        return NULL;
    }

    uint32_t n_slots = 0;
    r = ds_schema_get_slot_count(schema, &n_slots);
    if (r.status != DS_OK) return pyds_raise_from_result(r);

    ds_slot_value_t *values = NULL;
    if (pyds_build_slot_values(self, schema, schema_name, n_slots, kwds,
                                &values) != 0) {
        return NULL;
    }

    ds_fact_t *fact = NULL;
    r = ds_engine_assert(self->engine, schema, values, n_slots, &fact);
    /* JSON slot trees are caller-owned; free after assert serializes. */
    pyds_free_slot_values(values, n_slots);
    pyds_live_check(self);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    /* The fact's id. The FACT_ASSERT event put it in the table. */
    return pyds_fact_id_of(fact);
}

/* NO assert_with_ttl: a fact's deadline is its schema's TTL. */

static PyObject *
PydsEngine_retract(PydsEngineObject *self, PyObject *args)
{
    /* retract(fact_id): remove the live fact with that id. One that is not
       live -- already retracted, expired, superseded, never asserted -- is a
       KeyError; libds is only ever handed a pointer the table holds,
       which is what makes a second retract safe ([libds.h] calls it undefined
       behaviour). */
    PyObject *fid;
    if (!PyArg_ParseTuple(args, "O", &fid)) return NULL;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_fact_t *fact = pyds_live_find(self, fid);
    if (fact == NULL) return NULL;
    ds_result_t r = ds_engine_retract(self->engine, fact);
    pyds_live_check(self);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* NO WORKING-MEMORY BOUND AND NO POOL SIZING: they are realtime's, which
   libds.h does not declare ([NRTM.9.1]). */

/* set_cache_cap(*, cap_keys=0, cap_bytes=0) — the engine-owned cache's two
   bounds (LCSP.2.2): its live key count and its total value bytes, each 0 for
   unbounded. libds refuses a cache write past either with
   DS_ERR_CONTRACT_BREACH and changes nothing. Keyword-only, because the two
   are peers and a call site should say which it is setting. */
static PyObject *
PydsEngine_set_cache_cap(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = { "cap_keys", "cap_bytes", NULL };
    uint32_t cap_keys = 0;
    uint64_t cap_bytes = 0;
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|$O&O&", kwlist,
                                     pyds_u32_arg, &cap_keys,
                                     pyds_u64_arg, &cap_bytes)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_set_cache_cap(self->engine, cap_keys, cap_bytes);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* pump() takes no argument (NLFC.2.2): it runs the agenda to exhaustion,
   and nothing bounds one pump's work. METH_NOARGS, so CPython itself refuses
   an argument, positional or keyword, with TypeError. */
static PyObject *
PydsEngine_pump(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_pump(self->engine);
    pyds_live_check(self);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_fact_count(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    size_t count = 0;
    ds_result_t r = ds_engine_fact_count(self->engine, &count);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    return PyLong_FromSize_t(count);
}

/* The halt latch ([NCBK.2.11]): None while the engine runs; once an
   EngineError has halted it, the ds_engine_fault_t that did, the same number
   the engine_error event's `engine_fault` carries. A read, so it answers on a
   halted engine. pyds.Engine.halted makes it an EngineFault. */
static PyObject *
PydsEngine_halted(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    ds_result_t r = ds_engine_halted(self->engine, &halted, &fault);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    if (!halted) Py_RETURN_NONE;
    return PyLong_FromLong((long)fault);
}

/* ds_engine_mem as a dict, one key per ds_engine_mem_t field, same names;
   pyds.Engine.memory_usage makes it a pyds.MemoryUsage. */
static PyObject *
PydsEngine_mem(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_engine_mem_t m;
    ds_result_t r = ds_engine_mem(self->engine, &m);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    return Py_BuildValue(
        "{s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n,s:n}",
        "wm_fact_count",       (Py_ssize_t)m.wm_fact_count,
        "wm_fact_bytes",       (Py_ssize_t)m.wm_fact_bytes,
        "wm_index_bytes",      (Py_ssize_t)m.wm_index_bytes,
        "alpha_node_count",    (Py_ssize_t)m.alpha_node_count,
        "alpha_match_count",   (Py_ssize_t)m.alpha_match_count,
        "alpha_index_bytes",   (Py_ssize_t)m.alpha_index_bytes,
        "beta_node_count",     (Py_ssize_t)m.beta_node_count,
        "beta_token_count",    (Py_ssize_t)m.beta_token_count,
        "beta_token_bytes",    (Py_ssize_t)m.beta_token_bytes,
        "beta_index_bytes",    (Py_ssize_t)m.beta_index_bytes,
        "intern_count",        (Py_ssize_t)m.intern_count,
        "intern_string_bytes", (Py_ssize_t)m.intern_string_bytes,
        "intern_index_bytes",  (Py_ssize_t)m.intern_index_bytes,
        "pool_reserved_bytes", (Py_ssize_t)m.pool_reserved_bytes,
        "total_bytes",         (Py_ssize_t)m.total_bytes);
}

/* ---- Clock surface (RTIM.3) ----------------------------------
 * The primitives behind pyds.Engine.clock (pyds/engine.py). The mode
 * crosses as the string "live" / "mock", which pyds.ClockMode's members
 * are.
 */

static PyObject *
PydsEngine_clock_mode(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_clock_mode_t mode;
    ds_result_t r = ds_engine_clock_mode(self->engine, &mode);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyUnicode_FromString(mode == DS_CLOCK_MOCK ? "mock" : "live");
}

/* NO set_hydration_budget ([LHYD.7.4]). */


static PyObject *
PydsEngine_clock_set_mode(PydsEngineObject *self, PyObject *arg)
{
    if (!PyUnicode_Check(arg)) {
        PyObject *tn = pyds_type_name(arg);
        if (tn != NULL) {
            PyErr_Format(PyExc_TypeError, "clock mode must be a str, not %U", tn);
            Py_DECREF(tn);
        }
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    /* PyUnicode_CompareWithASCIIString compares the whole string, so
       "mock\0x" is not "mock", as a strcmp of its UTF-8 would take it to be.
       (PyUnicode_EqualToUTF8 says the same more directly, but is 3.13's.) */
    ds_clock_mode_t mode;
    if (PyUnicode_CompareWithASCIIString(arg, "live") == 0) {
        mode = DS_CLOCK_LIVE;
    }
    else if (PyUnicode_CompareWithASCIIString(arg, "mock") == 0) {
        mode = DS_CLOCK_MOCK;
    }
    else {
        PyErr_Format(PyExc_ValueError,
                     "clock mode must be \"live\" or \"mock\", not %R", arg);
        return NULL;
    }
    ds_result_t r = ds_engine_clock_set_mode(self->engine, mode);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_clock_now(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    uint64_t now_ns = 0;
    ds_result_t r = ds_engine_clock_now(self->engine, &now_ns);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    return PyLong_FromUnsignedLongLong((unsigned long long)now_ns);
}

static PyObject *
PydsEngine_clock_set(PydsEngineObject *self, PyObject *arg)
{
    uint64_t now_ns;
    if (!pyds_u64_arg(arg, &now_ns)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_clock_set(self->engine, now_ns);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_clock_advance(PydsEngineObject *self, PyObject *arg)
{
    uint64_t delta_ns;
    if (!pyds_u64_arg(arg, &delta_ns)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_clock_advance(self->engine, delta_ns);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_wall_clock_set(PydsEngineObject *self, PyObject *arg)
{
    /* Signed: a wall clock may stand before the epoch. Anything with
       __index__ is taken, as the "L" format took it; a value outside
       int64_t raises OverflowError. */
    PyObject *index = PyNumber_Index(arg);
    if (index == NULL) {
        return NULL;
    }
    long long utc_ns = PyLong_AsLongLong(index);
    Py_DECREF(index);
    if (utc_ns == -1 && PyErr_Occurred()) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_result_t r = ds_engine_wall_clock_set(self->engine, (int64_t)utc_ns);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* ---- Stream-event subscription -------------------------------- */

/* The event kind, log level, metric kind and series names come from
   runtime/src/bindings/ds_names.h, which @ds-lang/ds includes too: the strings are
   what a harness matches on, so both bindings read them from one table. */

/* Set dict[key] = value (where value is any PyObject *). On failure
   sets a Python exception and returns -1. Steals one reference from
   `value` on success or failure (consistent with PyDict_SetItem +
   Py_DECREF idiom). */
static int
pyds_dict_set_steal(PyObject *dict, const char *key, PyObject *value)
{
    if (value == NULL) return -1;
    int rc = PyDict_SetItemString(dict, key, value);
    Py_DECREF(value);
    return rc;
}

/* pyds.JsonText: a Json value's canonical text. It is a str, so code
   that treats Json as its text keeps working and json.loads takes it as it
   is. It is also its own type, so a Json value is told from a String holding
   the same characters by isinstance, which a plain str could not do. libds
   and the recording keep the two kinds apart (DS_ARG_JSON, KIND_JSON); before
   this, pyds was where they merged. The text is never parsed (PYTHON_BINDING.md
   §3.3). */
static PyObject *
JsonText_repr(PyObject *self)
{
    /* str's own repr, through its slot: PyTypeObject is opaque under the
       limited API (PY.16), so PyUnicode_Type.tp_repr cannot be read. */
    reprfunc str_repr = (reprfunc)PyType_GetSlot(&PyUnicode_Type, Py_tp_repr);
    PyObject *text = str_repr(self);
    if (text == NULL) return NULL;
    PyObject *r = PyUnicode_FromFormat("JsonText(%U)", text);
    Py_DECREF(text);
    return r;
}

/* A heap type, made from this spec once and kept (pyds_init_engine_type).
   A subclass of str: its size and layout are str's, so basicsize is 0. */
static PyType_Slot pyds_json_text_slots[] = {
    { Py_tp_doc, (void *)PyDoc_STR(
        "JsonText(text)\n--\n\n"
        "A DS Json value, as its canonical JSON text. A str: compare it, "
        "print it, or json.loads it. isinstance(v, pyds.JsonText) tells a Json "
        "value from a String.") },
    { Py_tp_repr, (void *)JsonText_repr },
    { 0, NULL },
};

static PyType_Spec pyds_json_text_spec = {
    .name      = "pyds.JsonText",
    .basicsize = 0,
    .itemsize  = 0,
    .flags     = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_IMMUTABLETYPE,   /* as _Engine's */
    .slots     = pyds_json_text_slots,
};

static PyObject *PydsJsonTextType;

/* JSON tree → its canonical text, as a pyds.JsonText. NULL tree returns
   Py_None. ds_json_serialize's buffer is libds's, so ds_free releases it,
   never libc free ([IALC.4.3]): they differ under an allocator
   override. */
static PyObject *
pyds_json_to_pystr(const ds_json_t *tree)
{
    if (tree == NULL) Py_RETURN_NONE;
    char  *text = NULL;
    size_t tlen = 0;
    ds_result_t r = ds_json_serialize(tree, &text, &tlen);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    PyObject *s = PyUnicode_FromStringAndSize(text, (Py_ssize_t)tlen);
    ds_free(text);
    if (s == NULL) return NULL;
    PyObject *j = PyObject_CallFunctionObjArgs(PydsJsonTextType, s, NULL);
    Py_DECREF(s);
    return j;
}

/* A fact passed as a call argument: its FactExternal encoding,
   and the two things libds lifts out of it for routing. A struct sequence,
   as os.stat_result is: a tuple whose fields also have names. `data` is what
   another engine's assert_external takes. */
static PyStructSequence_Field pyds_encoded_fact_fields[] = {
    { "schema",      "the fact's schema name" },
    { "asserted_at", "when the fact entered working memory: UTC ns since the Unix epoch, "
                     "or None if the wall clock had no value then (RFCS.23.5)" },
    { "data",        "the fact's FactExternal encoding, as bytes" },
    { NULL, NULL },
};

static PyStructSequence_Desc pyds_encoded_fact_desc = {
    "pyds.EncodedFact",
    "A fact passed as a call argument: (schema, asserted_at, data).",
    pyds_encoded_fact_fields,
    3,
};

static PyTypeObject *PydsEncodedFactType;

/* One typed call argument as a Python value. */
static PyObject *
pyds_arg_value_to_py(const ds_arg_value_t *v)
{
    switch (v->kind) {
    case DS_ARG_INT:    return PyLong_FromLongLong((long long)v->v.i);
    case DS_ARG_FLOAT:  return PyFloat_FromDouble(v->v.f);
    case DS_ARG_STRING: return PyUnicode_FromString(v->v.s ? v->v.s : "");
    case DS_ARG_BOOL:   return PyBool_FromLong(v->v.b);
    /* The canonical text, as for a Json slot, and never parsed: a parse would
       change integers past 64 bits, float spelling and duplicate keys
       without saying so (PYTHON_BINDING.md §3.3). */
    case DS_ARG_JSON:   return pyds_json_to_pystr(v->v.json);
    case DS_ARG_BYTES:
        return PyBytes_FromStringAndSize((const char *)v->v.bytes.data,
                                         (Py_ssize_t)v->v.bytes.len);
    /* A kwarg with no value prevents the call, so no callback receives one
       ([NCBK.6.10]). */
    case DS_ARG_NULL:   break;
    case DS_ARG_ENCODED_FACT: {
        PyObject *t = PyStructSequence_New(PydsEncodedFactType);
        if (t == NULL) return NULL;
        PyObject *schema = PyUnicode_FromString(v->v.fact.schema ? v->v.fact.schema : "");
        /* No wall clock at assertion: None, not a 0 that reads as 1970. */
        PyObject *at     = v->v.fact.asserted_at_set
                         ? PyLong_FromLongLong((long long)v->v.fact.asserted_at)
                         : Py_NewRef(Py_None);
        PyObject *data   = PyBytes_FromStringAndSize((const char *)v->v.fact.bytes.data,
                                                     (Py_ssize_t)v->v.fact.bytes.len);
        if (schema == NULL || at == NULL || data == NULL) {
            Py_XDECREF(schema);
            Py_XDECREF(at);
            Py_XDECREF(data);
            Py_DECREF(t);
            return NULL;
        }
        PyStructSequence_SetItem(t, 0, schema);   /* steals */
        PyStructSequence_SetItem(t, 1, at);
        PyStructSequence_SetItem(t, 2, data);
        return t;
    }
    }
    PyErr_Format(PyExc_ValueError, "a call argument of unknown kind %d", (int)v->kind);
    return NULL;
}

/* assert_external(data) -> None (NCBK.10.4): the way back in for the bytes
   an EncodedFact or a publish event hands out. `data` is a FactExternal as any
   bytes-like object, or a pyds.EncodedFact, whose `data` is taken. libds
   resolves its references (RFCS.23.7) and refuses the whole record, asserting
   nothing, on a parse failure or nesting past 16, an unknown schema, a
   schema_hash mismatch (-219) or a reference conflict (-220). libds returns no
   fact, so neither does this: what it asserted is in the stream. */
static PyObject *
PydsEngine_assert_external(PydsEngineObject *self, PyObject *data)
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    PyObject *src = PyObject_TypeCheck(data, PydsEncodedFactType)
                  ? PyStructSequence_GetItem(data, 2)   /* borrowed: .data */
                  : data;
    Py_buffer view;
    if (PyObject_GetBuffer(src, &view, PyBUF_SIMPLE) < 0) return NULL;
    ds_result_t r = ds_engine_assert_external(self->engine, (const uint8_t *)view.buf,
                                              (size_t)view.len);
    PyBuffer_Release(&view);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* A call's typed arguments as a dict, kwarg name -> value, in
   the order libds gives them: sorted by name. A kwarg the call omits is
   absent. */
static PyObject *
pyds_args_to_dict(const ds_arg_t *args, uint32_t n)
{
    PyObject *d = PyDict_New();
    if (d == NULL) return NULL;
    for (uint32_t i = 0; i < n; i++) {
        if (pyds_dict_set_steal(d, args[i].name ? args[i].name : "",
                                 pyds_arg_value_to_py(&args[i].value)) < 0) {
            Py_DECREF(d);
            return NULL;
        }
    }
    return d;
}

/* The call's correlation: its `as` value, or the one the compiler generated
   for a call with none ([LCRS.3.1], [LCCO.3.4]). Always a str.
   libds.h says the field is never NULL, so a NULL is a runtime defect against
   [LCRS.3.1]: raised, never passed on as None. */
static PyObject *
pyds_correlation_to_py(const char *correlation)
{
    if (correlation == NULL) {
        PyErr_SetString(PyExc_SystemError,
            "libds issued a call with no correlation ([LCRS.3.1])");
        return NULL;
    }
    return PyUnicode_FromString(correlation);
}

/* Defined below, with the working-memory read-outs it serves too. */
static PyObject *pyds_fact_slots(const ds_fact_t *fact,
                                 const char **out_schema_name,
                                 ds_result_t *out_r);

/* Build a Python dict for one stream event. Common fields (seq /
   clock_ns / kind) always present; per-kind fields populated only
   for kinds the trampoline knows. */
static PyObject *
pyds_event_to_dict(const ds_stream_ev_t *ev)
{
    PyObject *d = PyDict_New();
    if (d == NULL) return NULL;
    if (pyds_dict_set_steal(d, "seq",
            PyLong_FromUnsignedLongLong(ev->seq)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "clock_ns",
            PyLong_FromUnsignedLongLong(ev->clock_ns)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "kind",
            PyUnicode_FromString(ds_names_event_kind(ev->kind))) < 0) goto fail;

    switch (ev->kind) {
    case DS_EV_FACT_ASSERT:
    case DS_EV_FACT_RETRACT:
    case DS_EV_FACT_MODIFY: {
        /* The fact by its id, which pyds.Engine.facts takes -- inside
           the retract callback too: the table drops the fact after the
           callback has seen it. */
        ds_fact_t *fact = (ev->kind == DS_EV_FACT_ASSERT)   ? ev->p.fact_assert.fact
                        : (ev->kind == DS_EV_FACT_RETRACT)  ? ev->p.fact_retract.fact
                                                            : ev->p.fact_modify.fact;
        if (pyds_dict_set_steal(d, "fact_id", pyds_fact_id_of(fact)) < 0) goto fail;
        break;
    }
    case DS_EV_RULE_FIRE_BEGIN:
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.rule_fire_begin.rule_name)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.rule_fire_begin.timetag)) < 0) goto fail;
        break;
    case DS_EV_RULE_FIRE_END:
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.rule_fire_end.rule_name)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.rule_fire_end.timetag)) < 0) goto fail;
        break;
    case DS_EV_ACTION_PUBLISH: {
        /* [NCBK.2.5]: the event's fact is a view, valid for the callback only,
           with no id: a `publish` puts nothing in working memory ([LTIE.4.3]),
           so no FactId could find it afterwards. Its schema and slot values
           are copied here, the only time they can be read, with the values
           pyds_fact_slots gives a fact in working memory. */
        const ds_fact_t *view = ev->p.action_publish.fact;
        const char *schema_name = NULL;
        ds_result_t sr = DS_OK_R;
        PyObject *slots = (view != NULL)
            ? pyds_fact_slots(view, &schema_name, &sr) : NULL;
        if (slots == NULL) {
            if (!PyErr_Occurred())
                PyErr_Format(PyExc_RuntimeError,
                    "action_publish: libds gave no readable view (status %d)",
                    (int)sr.status);
            goto fail;
        }
        if (pyds_dict_set_steal(d, "schema",
                PyUnicode_FromString(schema_name ? schema_name : "")) < 0) {
            Py_DECREF(slots);
            goto fail;
        }
        if (pyds_dict_set_steal(d, "slots", slots) < 0) goto fail;
        /* [NCBK.10.1] — the FactExternal another tier's assert_external
           takes; copied, since libds's bytes last only for the callback. */
        if (pyds_dict_set_steal(d, "external",
                PyBytes_FromStringAndSize(
                    (const char *)ev->p.action_publish.external,
                    (Py_ssize_t)ev->p.action_publish.external_len)) < 0) goto fail;
        break;
    }
    case DS_EV_ACTION_EMIT:
        if (pyds_dict_set_steal(d, "fact_id",
                pyds_fact_id_of(ev->p.action_emit.fact)) < 0) goto fail;
        break;
    case DS_EV_ACTION_LOG:
        if (pyds_dict_set_steal(d, "level",
                PyUnicode_FromString(ds_names_log_level(ev->p.action_log.level))) < 0) goto fail;
        if (pyds_dict_set_steal(d, "category",
                PyUnicode_FromString(ev->p.action_log.category
                                         ? ev->p.action_log.category : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "message",
                PyUnicode_FromString(ev->p.action_log.message
                                         ? ev->p.action_log.message : "")) < 0) goto fail;
        break;
    case DS_EV_ACTION_CACHE_SET:
        if (pyds_dict_set_steal(d, "key",
                PyUnicode_FromString(ev->p.action_cache_set.key
                                         ? ev->p.action_cache_set.key : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "value_json",
                pyds_json_to_pystr(ev->p.action_cache_set.value)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "ttl_ns",
                PyLong_FromUnsignedLongLong(ev->p.action_cache_set.ttl_ns)) < 0) goto fail;
        break;
    case DS_EV_ACTION_CACHE_GET:
        if (pyds_dict_set_steal(d, "key",
                PyUnicode_FromString(ev->p.action_cache_get.key
                                         ? ev->p.action_cache_get.key : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "value_json",
                pyds_json_to_pystr(ev->p.action_cache_get.value)) < 0) goto fail;
        break;
    case DS_EV_ACTION_CACHE_DELETE:
        if (pyds_dict_set_steal(d, "key",
                PyUnicode_FromString(ev->p.action_cache_delete.key
                                         ? ev->p.action_cache_delete.key : "")) < 0) goto fail;
        break;
    case DS_EV_ACTION_CALL:
        if (pyds_dict_set_steal(d, "service",
                PyUnicode_FromString(ev->p.action_call.service
                                         ? ev->p.action_call.service : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "correlation",
                pyds_correlation_to_py(ev->p.action_call.correlation)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "args",
                pyds_args_to_dict(ev->p.action_call.args,
                                   ev->p.action_call.arg_count)) < 0) goto fail;
        /* Fire identity — (timetag, rule_name) is byte-identical to the
           bracketing RuleFireAnnotation's, the CallIssued↔RuleFireAnnotation
           join key (RFCS.15.2 / RFCS.11.2). */
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.action_call.timetag)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.action_call.rule_name
                                         ? ev->p.action_call.rule_name : "")) < 0) goto fail;
        break;
    case DS_EV_RULE_LHS_FACTS: {
        /* rule_name + lhs_facts, the matched facts' FactIds in pattern order;
           libds passes only the facts it found. timetag is the firing's, the
           key that joins this event to its rule_fire_begin ([NCBK.2.12]). */
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.rule_lhs_facts.rule_name
                                         ? ev->p.rule_lhs_facts.rule_name : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.rule_lhs_facts.timetag)) < 0) goto fail;
        PyObject *fl = PyList_New((Py_ssize_t)ev->p.rule_lhs_facts.fact_count);
        if (!fl) goto fail;
        for (uint32_t i = 0; i < ev->p.rule_lhs_facts.fact_count; i++) {
            PyObject *h = pyds_fact_id_of(ev->p.rule_lhs_facts.facts[i]);
            if (!h) { Py_DECREF(fl); goto fail; }
            PyList_SetItem(fl, (Py_ssize_t)i, h); /* steals h */
        }
        if (pyds_dict_set_steal(d, "lhs_facts", fl) < 0) goto fail;
        break;
    }
    case DS_EV_TIMER_ARMED:
        /* timetag is the arming firing's ([NCBK.2.12]). No event reports the
           timer firing: DS_EV_TIMER_FIRED is reserved and never emitted
           ([NCBK.2.4]), so it has no arm here. */
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.timer_armed.rule_name
                                         ? ev->p.timer_armed.rule_name : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.timer_armed.timetag)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timer_kind",
                PyUnicode_FromString(ev->p.timer_armed.kind
                                         ? ev->p.timer_armed.kind : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "window_ns",
                PyLong_FromUnsignedLongLong(ev->p.timer_armed.window_ns)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "fire_at_ns",
                PyLong_FromUnsignedLongLong(ev->p.timer_armed.fire_at_ns)) < 0) goto fail;
        break;
    /* Fault payloads. The enums go over as their integer values, which are the
       proto numbers; a NULL string goes over as None, because absence is what
       the recorder meant by it. A fault's rule_name is never NULL
       ([LERR.9.11]), but for a bound's, which may have none. */
    case DS_EV_TYPE_ERROR:
        if (pyds_dict_set_steal(d, "node_id",
                PyLong_FromUnsignedLong(ev->p.type_error.node_id)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "schema_name", ev->p.type_error.schema_name
                ? PyUnicode_FromString(ev->p.type_error.schema_name)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "slot_name", ev->p.type_error.slot_name
                ? PyUnicode_FromString(ev->p.type_error.slot_name)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "actual", ev->p.type_error.actual
                ? PyUnicode_FromString(ev->p.type_error.actual)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.type_error.rule_name
                                         ? ev->p.type_error.rule_name : "")) < 0) goto fail;
        break;
    case DS_EV_BOUNDS_ERROR:
        if (pyds_dict_set_steal(d, "cap",
                PyLong_FromLong((long)ev->p.bounds_error.cap)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "limit",
                PyLong_FromUnsignedLongLong(ev->p.bounds_error.limit)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "observed",
                PyLong_FromUnsignedLongLong(ev->p.bounds_error.observed)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "rule_name", ev->p.bounds_error.rule_name
                ? PyUnicode_FromString(ev->p.bounds_error.rule_name)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.bounds_error.timetag)) < 0) goto fail;
        break;
    case DS_EV_ENGINE_ERROR:
        if (pyds_dict_set_steal(d, "engine_fault",
                PyLong_FromLong((long)ev->p.engine_error.fault)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "node_id",
                PyLong_FromUnsignedLong(ev->p.engine_error.node_id)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.engine_error.rule_name
                                         ? ev->p.engine_error.rule_name : "")) < 0) goto fail;
        break;
    case DS_EV_COMPUTATION_ERROR:
        if (pyds_dict_set_steal(d, "trap_kind",
                PyLong_FromLong((long)ev->p.computation_error.kind)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "rule_name",
                PyUnicode_FromString(ev->p.computation_error.rule_name
                                         ? ev->p.computation_error.rule_name : "")) < 0) goto fail;
        if (pyds_dict_set_steal(d, "timetag",
                PyLong_FromLongLong(ev->p.computation_error.timetag)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "schema_name", ev->p.computation_error.schema_name
                ? PyUnicode_FromString(ev->p.computation_error.schema_name)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "slot_name", ev->p.computation_error.slot_name
                ? PyUnicode_FromString(ev->p.computation_error.slot_name)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "fact_id", ev->p.computation_error.fact_id
                ? pyds_fact_id(ev->p.computation_error.fact_id)
                : Py_NewRef(Py_None)) < 0) goto fail;
        if (pyds_dict_set_steal(d, "node_id",
                PyLong_FromUnsignedLong(ev->p.computation_error.node_id)) < 0) goto fail;
        break;
    case DS_EV_TICK:
        /* The wall sample ([LTIM.2.8.3]); None while the wall clock has no
           value, which is a state and not the epoch. clock_ns is the
           monotonic sample, set above for every kind. */
        if (pyds_dict_set_steal(d, "wall_ns", ev->p.tick.wall_set
                ? PyLong_FromLongLong(ev->p.tick.wall_ns)
                : Py_NewRef(Py_None)) < 0) goto fail;
        break;
    default:
        break;
    }
    return d;

fail:
    Py_DECREF(d);
    return NULL;
}

/* The Python stream callback, if one is set. Per the stream-callback
   contract, pointers in the payload are valid only for the callback's
   duration, so everything is marshalled into Python objects first.

   pump() runs with the GIL held, and so does this: an engine is not entered
   from two threads at once. */
static ds_result_t
pyds_stream_trampoline(ds_engine_t *engine,
                         const ds_stream_ev_t *ev,
                         void *user)
{
    (void)engine;
    PydsEngineObject *self = (PydsEngineObject *)user;
    if (self == NULL || self->stream_cb == NULL) return DS_OK_R;

    /* Held for the call: the callback may replace itself. */
    PyObject *cb = Py_NewRef(self->stream_cb);
    PyObject *event_dict = pyds_event_to_dict(ev);
    if (event_dict == NULL) {
        cb_keep(self, cb);
        Py_DECREF(cb);
        return DS_OK_R;
    }
    PyObject *result = PyObject_CallFunctionObjArgs(cb, event_dict, NULL);
    Py_DECREF(event_dict);
    if (result == NULL) {
        /* Don't propagate to libds — pump would unwind, hiding
           subsequent events that might also be informative. The
           exception is kept like any callback's, and as an observer's
           cannot fail the call, it reaches the caller only as the
           cause of a failure something else made. */
        cb_keep(self, cb);
    } else {
        Py_DECREF(result);
    }
    Py_DECREF(cb);
    return DS_OK_R;
}

/* The engine's stream callback, installed for the engine's whole life
   the live-fact table, then the recorder, then Python.

   A fact enters the table before anything hears of its assert, and leaves it
   after everything has heard of its retract, so pyds.Engine.facts answers
   inside both callbacks. A failed insert marks the table stale instead of failing
   the event: the next lookup rebuilds it.

   RECTEE1 — the C recorder runs before the Python callback, so the event's
   atom is in the sink before Python hears of the event, inside the engine's
   event dispatch exactly as it would alone. Its outcome is returned, not
   discarded: an atom it lost is the status of the call that fired
   the event ([NCBK.1.5]). The Python callback runs either way, and the
   recorder's failure wins, being the first. */
static ds_result_t
pyds_on_event(ds_engine_t *engine, const ds_stream_ev_t *ev, void *user)
{
    PydsEngineObject *self = (PydsEngineObject *)user;
    if (self == NULL) return DS_OK_R;

    if (self->live != NULL) {
        const ds_fact_t *added = ev->kind == DS_EV_FACT_ASSERT ? ev->p.fact_assert.fact
                               : ev->kind == DS_EV_FACT_MODIFY ? ev->p.fact_modify.fact
                               : NULL;
        if (added != NULL && pyds_live_put(self, added) < 0) {
            PyErr_Clear();
            self->live_stale = 1;
        }
    }

    ds_result_t rec = self->recfile != NULL
        ? ds_rfcs_recorder_on_event(engine, ev, &self->rec) : DS_OK_R;
    ds_result_t cb  = pyds_stream_trampoline(engine, ev, user);

    if (ev->kind == DS_EV_FACT_RETRACT && self->live != NULL) {
        uint64_t id = 0;
        PyObject *key = ds_fact_get_id(ev->p.fact_retract.fact, &id).status == DS_OK
            ? PyLong_FromUnsignedLongLong((unsigned long long)id) : NULL;
        if (key == NULL || (PyDict_DelItem(self->live, key) < 0
                            && !PyErr_ExceptionMatches(PyExc_KeyError))) {
            self->live_stale = 1;
        }
        PyErr_Clear();
        Py_XDECREF(key);
    }
    return rec.status != DS_OK ? rec : cb;
}

static PyObject *
PydsEngine_set_stream_callback(PydsEngineObject *self, PyObject *cb)
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    /* The engine's registration is pyds_on_event for its whole life
       which reads `stream_cb` on every event, so only the Python
       reference changes here. */
    if (cb != Py_None && !PyCallable_Check(cb)) {
        PyErr_SetString(PyExc_TypeError,
            "the stream callback must be a callable or None");
        return NULL;
    }
    PyObject *old_cb = self->stream_cb;
    self->stream_cb = cb == Py_None ? NULL : Py_NewRef(cb);
    Py_XDECREF(old_cb);
    Py_RETURN_NONE;
}

/* ---- Integrator-side typed callbacks (RTIM.4) ----------------
 * Each callback is wrapped the same way: PydsEngineObject holds a
 * strong reference to the Python callable; the trampoline marshals
 * the libds event into a Python dict and invokes the callable.
 *
 * A CALLBACK THAT RAISED HAS FAILED, AND LIBDS IS TOLD. libds acts
 * on the status a typed callback returns ([NCBK.1.5]): a failed `call` is
 * reported by pump, a failed persistence write
 * is reported ([NCBK.7.5]), and a failed sample is counted as
 * dropped_total{reason="cb_error"} ([NSTG.5.3.2]). Answering DS_OK for a
 * handler that raised told libds the work had been done. So the
 * trampoline returns DS_ERR_ACTION_FAILED, the code [NERR.6] reserves for
 * callback-reported failures, as rust_plusds does for a handler that
 * panicked. A dict that could not be built is a failure too — the callable
 * never saw the event.
 *
 * The exception itself is kept by `cb_keep`, the first of the libds call:
 * libds carries on through the rest of the call and enters Python again, so
 * it cannot stay set. `cb_settle` hands it on when the call returns, as the
 * __cause__ of the pyds.Error a failed call raises, or to
 * sys.unraisablehook after a call that succeeded (PYTHON_BINDING.md §2.3).
 *
 * The stream callback keeps answering DS_OK: [NCBK.1.5] makes it an
 * observer. Its exception is kept like the others, and cannot fail the
 * call itself.
 *
 * The setters share two helpers: a swap that orders the libds
 * registration before dropping the old PyObject (so no event ever
 * fires into freed memory), and a None-passes-through path that
 * unregisters cleanly.
 */

/* Helper: swap *slot to a new PyObject (NULL = unset). Caller is
   responsible for the libds-side registration around this call.
   Increments cb's refcount and decrements the old slot's. */
static void
pyds_swap_cb(PyObject **slot, PyObject *cb)
{
    PyObject *old = *slot;
    if (cb != NULL) Py_INCREF(cb);
    *slot = cb;
    Py_XDECREF(old);
}

/* Helper: a typed callback failed (a Python exception is set). Keep the
   exception and tell libds — see the section comment. */
static ds_result_t
pyds_cb_failed(PydsEngineObject *self, PyObject *cb)
{
    cb_keep(self, cb);
    return DS_ERR_R(DS_ERR_ACTION_FAILED, "pyds: the Python callback raised");
}

/* Helper: validate cb is None or callable. Returns 0 on OK,
   sets exception + returns -1 otherwise. *out is the cb to swap
   in (NULL when cb was None). */
static int
pyds_unpack_cb(PyObject *cb, PyObject **out, const char *what)
{
    if (cb == Py_None) { *out = NULL; return 0; }
    if (!PyCallable_Check(cb)) {
        PyErr_Format(PyExc_TypeError,
            "%s expects a callable or None", what);
        return -1;
    }
    *out = cb;
    return 0;
}

/* ---- Call callback ------------------------------------------ */

static ds_result_t
pyds_call_trampoline(ds_engine_t *engine,
                      const ds_call_request_t *req,
                      void *user)
{
    (void)engine;
    PydsEngineObject *self = user;
    if (self == NULL || self->call_cb == NULL) return DS_OK_R;

    PyObject *d = PyDict_New();
    if (d == NULL) goto unraisable;
    if (pyds_dict_set_steal(d, "service",
            PyUnicode_FromString(req->service ? req->service : "")) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "correlation",
            pyds_correlation_to_py(req->correlation)) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "args",
            pyds_args_to_dict(req->args, req->arg_count)) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    /* The firing activation's identity, the
       CallIssued/RuleFireAnnotation join key of [RFCS.15]. Never NULL
       ([NCBK.2.12], libds.h). The stream's DS_EV_ACTION_CALL already carried
       both, and the request did not. */
    if (pyds_dict_set_steal(d, "timetag",
            PyLong_FromLongLong((long long)req->timetag)) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "rule_name",
            PyUnicode_FromString(req->rule_name)) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    PyObject *result = PyObject_CallFunctionObjArgs(self->call_cb, d, NULL);
    Py_DECREF(d);
    if (result == NULL) goto unraisable;
    Py_DECREF(result);
    return DS_OK_R;

unraisable:
    return pyds_cb_failed(self, self->call_cb);
}

static PyObject *
PydsEngine_set_call_callback(PydsEngineObject *self, PyObject *args)
{
    PyObject *cb, *to_set;
    if (!PyArg_ParseTuple(args, "O", &cb)) return NULL;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (pyds_unpack_cb(cb, &to_set, "set_call_callback") < 0) return NULL;
    ds_result_t r = ds_engine_set_call_callback(
        self->engine, to_set ? pyds_call_trampoline : NULL,
        to_set ? self : NULL);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    pyds_swap_cb(&self->call_cb, to_set);
    Py_RETURN_NONE;
}

/* ---- cache persistence callbacks (set / delete) -------------
 * CACHEENG1 ([NCBK.7]): the cache is engine-owned and read engine-locally
 * (no get callback). These optional trampolines mirror writes outbound to a
 * Python-side durable store. */

static ds_result_t
pyds_cache_set_trampoline(ds_engine_t *engine,
                            const ds_cache_write_t *write,
                            void *user)
{
    (void)engine;
    PydsEngineObject *self = user;
    if (self == NULL || self->cache_set_cb == NULL) return DS_OK_R;

    PyObject *key_o   = PyUnicode_FromString(write->key ? write->key : "");
    PyObject *val_o   = pyds_json_to_pystr(write->value);
    PyObject *ttl_o   = PyLong_FromUnsignedLongLong(write->ttl_ns);
    if (key_o == NULL || val_o == NULL || ttl_o == NULL) {
        Py_XDECREF(key_o); Py_XDECREF(val_o); Py_XDECREF(ttl_o);
        goto unraisable;
    }
    PyObject *result = PyObject_CallFunctionObjArgs(
        self->cache_set_cb, key_o, val_o, ttl_o, NULL);
    Py_DECREF(key_o); Py_DECREF(val_o); Py_DECREF(ttl_o);
    if (result == NULL) goto unraisable;
    Py_DECREF(result);
    return DS_OK_R;

unraisable:
    return pyds_cb_failed(self, self->cache_set_cb);
}

static ds_result_t
pyds_cache_delete_trampoline(ds_engine_t *engine,
                               const ds_cache_removal_t *removal,
                               void *user)
{
    (void)engine;
    PydsEngineObject *self = user;
    if (self == NULL || self->cache_delete_cb == NULL) return DS_OK_R;

    const char *key = (removal && removal->key) ? removal->key : "";
    /* The reason reaches Python too, so a conformance vector can assert it
       rather than only that a delete arrived. */
    const char *reason = removal ? ds_names_cache_removal(removal->reason)
                                 : "delete";

    PyObject *result = PyObject_CallFunction(self->cache_delete_cb,
                                             "ss", key, reason);
    if (result == NULL)
        return pyds_cb_failed(self, self->cache_delete_cb);
    Py_DECREF(result);
    return DS_OK_R;
}

static PyObject *
PydsEngine_set_cache_callbacks(PydsEngineObject *self,
                                PyObject *args, PyObject *kwds)
{
    /* CACHEENG1: two optional persistence kwargs (no get — the cache is
       engine-owned and read engine-locally). Default each to None (= unset,
       volatile cache). */
    PyObject *set_cb    = Py_None;
    PyObject *delete_cb = Py_None;
    static char *kwlist[] = { "set_cb", "delete_cb", NULL };
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|OO", kwlist,
                                      &set_cb, &delete_cb)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }

    PyObject *set_set, *delete_set;
    if (pyds_unpack_cb(set_cb,    &set_set,    "_set_cache_callbacks(set_cb=)") < 0) return NULL;
    if (pyds_unpack_cb(delete_cb, &delete_set,
                        "_set_cache_callbacks(delete_cb=)") < 0) return NULL;

    ds_result_t r = ds_engine_cache_callbacks(
        self->engine, DS_CACHE_CB_ABI_VERSION,
        set_set    ? pyds_cache_set_trampoline    : NULL,
        delete_set ? pyds_cache_delete_trampoline : NULL,
        self);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    pyds_swap_cb(&self->cache_set_cb,    set_set);
    pyds_swap_cb(&self->cache_delete_cb, delete_set);
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_cache_seed(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    /* Seed the engine-owned cache before the run (a startup restore, or the
       .dstest `initial: cache "k": v` arrange). The value crosses the
       boundary as JSON text (the persisted / compiled form) and is parsed to a
       ds_json_t here, once, at setup, the same path an integrator restore
       takes. ds_engine_cache_seed then
       serialize-and-copies the tree canonically, so a seed and a rule cache-write
       with the same logical JSON store byte-identically. Caller retains nothing —
       we own and free the tree. */
    const char *key        = NULL;
    const char *value_json = NULL;
    Py_ssize_t  value_len  = 0;
    uint64_t ttl_ns = 0;
    static char *kwlist[] = { "key", "value_json", "ttl_ns", NULL };
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "ss#|O&", kwlist,
                                      &key, &value_json, &value_len,
                                      pyds_u64_arg, &ttl_ns)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }

    ds_json_t *tree = NULL;
    ds_result_t pr = ds_json_parse(value_json, (size_t)value_len, &tree);
    if (pr.status != DS_OK) return pyds_raise_from_result(pr);

    ds_result_t r = ds_engine_cache_seed(self->engine, key, tree,
                                         (uint64_t)ttl_ns);
    ds_json_free(tree);
    if (cb_settle(self, r) < 0) {
        return NULL;
    }
    Py_RETURN_NONE;
}

/* ---- Log / metric callbacks ----------------------------------
 * Smaller surface than the cache/call cbs — each
 * is a single typed callback with silent-drop NULL policy
 * (log + metric are per IARC.1.14 routing-only). Same trampoline
 * pattern.
 *
 * ALRT1 rung 7 — the alert trampoline and set_alert_callback stood here.
 * The C surface they bind to is gone, so they could not compile; a host
 * wanting the same channel registers a log callback and filters on
 * CRITICAL, which is where the verb migrated. */

static ds_result_t
pyds_log_trampoline(ds_engine_t *engine,
                     const ds_log_event_t *ev,
                     void *user)
{
    (void)engine;
    PydsEngineObject *self = user;
    if (self == NULL || self->log_cb == NULL) return DS_OK_R;
    PyObject *d = PyDict_New();
    if (d == NULL) goto unraisable;
    if (pyds_dict_set_steal(d, "level",
            PyUnicode_FromString(ds_names_log_level(ev->level))) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "category",
            PyUnicode_FromString(ev->category ? ev->category : "")) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "message",
            PyUnicode_FromString(ev->message ? ev->message : "")) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    PyObject *result = PyObject_CallFunctionObjArgs(self->log_cb, d, NULL);
    Py_DECREF(d);
    if (result == NULL) goto unraisable;
    Py_DECREF(result);
    return DS_OK_R;

unraisable:
    return pyds_cb_failed(self, self->log_cb);
}

static PyObject *
PydsEngine_set_log_callback(PydsEngineObject *self, PyObject *cb)
{
    PyObject *to_set;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (pyds_unpack_cb(cb, &to_set, "_set_log_callback") < 0) return NULL;
    ds_result_t r = ds_engine_set_log_callback(
        self->engine, to_set ? pyds_log_trampoline : NULL,
        to_set ? self : NULL);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    pyds_swap_cb(&self->log_cb, to_set);
    Py_RETURN_NONE;
}

static ds_result_t
pyds_metric_trampoline(ds_engine_t *engine,
                        const ds_metric_t *m,
                        void *user)
{
    (void)engine;
    PydsEngineObject *self = user;
    if (self == NULL || self->metric_cb == NULL) return DS_OK_R;
    PyObject *d = PyDict_New();
    if (d == NULL) goto unraisable;
    if (pyds_dict_set_steal(d, "name",
            PyUnicode_FromString(m->name ? m->name : "")) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "kind",
            PyUnicode_FromString(ds_names_metric_kind(m->kind))) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    if (pyds_dict_set_steal(d, "value",
            PyFloat_FromDouble(m->value)) < 0) {
        Py_DECREF(d); goto unraisable;
    }
    PyObject *labels = PyDict_New();
    if (labels == NULL) { Py_DECREF(d); goto unraisable; }
    for (uint32_t i = 0; i < m->n_labels; i++) {
        PyObject *v = PyUnicode_FromString(
            m->labels[i].value ? m->labels[i].value : "");
        if (v == NULL) {
            Py_DECREF(labels); Py_DECREF(d); goto unraisable;
        }
        if (PyDict_SetItemString(labels,
                m->labels[i].key ? m->labels[i].key : "",
                v) < 0) {
            Py_DECREF(v); Py_DECREF(labels); Py_DECREF(d); goto unraisable;
        }
        Py_DECREF(v);
    }
    if (PyDict_SetItemString(d, "labels", labels) < 0) {
        Py_DECREF(labels); Py_DECREF(d); goto unraisable;
    }
    Py_DECREF(labels);
    PyObject *result = PyObject_CallFunctionObjArgs(self->metric_cb, d, NULL);
    Py_DECREF(d);
    if (result == NULL) goto unraisable;
    Py_DECREF(result);
    return DS_OK_R;

unraisable:
    return pyds_cb_failed(self, self->metric_cb);
}

static PyObject *
PydsEngine_set_metric_callback(PydsEngineObject *self, PyObject *cb)
{
    PyObject *to_set;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (pyds_unpack_cb(cb, &to_set, "_set_metric_callback") < 0) return NULL;
    ds_result_t r = ds_engine_set_metric_callback(
        self->engine, to_set ? pyds_metric_trampoline : NULL,
        to_set ? self : NULL);
    if (r.status != DS_OK) return pyds_raise_from_result(r);
    pyds_swap_cb(&self->metric_cb, to_set);
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_platform_signature(PydsEngineObject *self,
                              PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_platform_signature_t sig;
    ds_result_t r = ds_engine_get_platform_signature(self->engine, &sig);
    if (r.status != DS_OK) return pyds_raise_from_result(r);

    PyObject *d = PyDict_New();
    if (d == NULL) return NULL;
    if (pyds_dict_set_steal(d, "os_family",
            PyUnicode_FromString(sig.os_family)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "cpu_arch",
            PyUnicode_FromString(sig.cpu_arch)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "libc",
            PyUnicode_FromString(sig.libc)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "compiler",
            PyUnicode_FromString(sig.compiler)) < 0) goto fail;
    if (pyds_dict_set_steal(d, "libds_version",
            PyUnicode_FromString(sig.libds_version)) < 0) goto fail;

    PyObject *backends = PyList_New((Py_ssize_t) sig.n_backends);
    if (backends == NULL) goto fail;
    for (size_t i = 0; i < sig.n_backends; i++) {
        PyObject *s = PyUnicode_FromString(
            sig.backends[i] ? sig.backends[i] : "");
        if (s == NULL) {
            Py_DECREF(backends);
            goto fail;
        }
        PyList_SetItem(backends, (Py_ssize_t) i, s);
    }
    if (pyds_dict_set_steal(d, "backends", backends) < 0) goto fail;
    return d;

fail:
    Py_DECREF(d);
    return NULL;
}

/* The session header ([RFCS.4.1]) as a dict: ds_version, session_id and
   tier_id (str, "" for none), then the dialect-binding tuple ([RBND.1.3]):
   dsc_hash and dialect_def_sha256 (32 bytes each, or None before a load) and
   capabilities (a tuple of Capability numbers in the DSC header's order,
   empty before a load). pyds.Engine.session_header makes it a
   pyds.SessionHeader. */
static PyObject *
PydsEngine_session_header(PydsEngineObject *self, PyObject *Py_UNUSED(args))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_session_header_t hdr;
    ds_result_t r = ds_engine_get_session_header(self->engine, &hdr);
    if (r.status != DS_OK) return pyds_raise_from_result(r);

    PyObject *d = PyDict_New();
    if (d == NULL) return NULL;
    /* [LDET.1.10] — `ds_version` replaces the `version` key. One version, and
       it is the DS version; the fact-stream format number it used to carry is
       struck. */
    if (pyds_dict_set_steal(d, "ds_version",
            PyUnicode_FromString(hdr.ds_version ? hdr.ds_version : "")) < 0)
        goto fail;
    if (pyds_dict_set_steal(d, "session_id",
            PyUnicode_FromString(hdr.session_id ? hdr.session_id : "")) < 0) goto fail;
    if (pyds_dict_set_steal(d, "tier_id",
            PyUnicode_FromString(hdr.tier_id ? hdr.tier_id : "")) < 0) goto fail;

    PyObject *dsc_hash;
    if (hdr.dsc_hash != NULL) {
        dsc_hash = PyBytes_FromStringAndSize(
            (const char *) hdr.dsc_hash, (Py_ssize_t) hdr.dsc_hash_len);
    } else {
        dsc_hash = (Py_INCREF(Py_None), Py_None);
    }
    if (pyds_dict_set_steal(d, "dsc_hash", dsc_hash) < 0) goto fail;

    PyObject *caps = PyTuple_New((Py_ssize_t) hdr.n_capabilities);
    if (caps == NULL) {
        goto fail;
    }
    for (size_t i = 0; i < hdr.n_capabilities; i++) {
        PyObject *n = PyLong_FromUnsignedLong(
            (unsigned long) hdr.capabilities[i]);
        if (n == NULL) {
            Py_DECREF(caps);
            goto fail;
        }
        PyTuple_SetItem(caps, (Py_ssize_t) i, n);  /* steals n */
    }
    if (pyds_dict_set_steal(d, "capabilities", caps) < 0) {
        goto fail;
    }

    PyObject *dialect;
    if (hdr.dialect_def_sha256 != NULL) {
        dialect = PyBytes_FromStringAndSize(
            (const char *) hdr.dialect_def_sha256,
            (Py_ssize_t) hdr.dialect_def_sha256_len);
    } else {
        dialect = Py_NewRef(Py_None);
    }
    if (pyds_dict_set_steal(d, "dialect_def_sha256", dialect) < 0) {
        goto fail;
    }
    return d;

fail:
    Py_DECREF(d);
    return NULL;
}

/* NO SERIES READ AND NO SAMPLES PLANE: no public function reads a series
   ([NSBK.6.3]), and NSTG.5 is deferred. */

/* The slots of a live fact as a Python dict, and its schema's name.
 *
 * ONE decoder for the two read-outs of working memory -- _fact (a fact the
 * stream named) and _facts (the walk below) -- so a value's
 * Python spelling is decided once and the two cannot disagree about it:
 *
 *   Int → int    Float → float    String → str    Bool → bool
 *   Json → str (JSON text)        Bytes → bytes   null → None
 *   fact-ref → the target's FactId, whether or not the target is still in
 *              working memory (ds_fact_get_slot_ref_id)
 *
 * On a libds failure the ds_result_t is returned through *out_r with NULL;
 * on a Python failure the exception is set and *out_r is DS_OK_R. */
static PyObject *
pyds_fact_slots(const ds_fact_t *fact, const char **out_schema_name,
                 ds_result_t *out_r)
{
    *out_r = DS_OK_R;

    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_fact_get_schema(fact, &schema);
    if (r.status != DS_OK) { *out_r = r; return NULL; }

    r = ds_schema_get_name(schema, out_schema_name);
    if (r.status != DS_OK) { *out_r = r; return NULL; }

    uint32_t n_slots = 0;
    r = ds_fact_get_slot_count(fact, &n_slots);
    if (r.status != DS_OK) { *out_r = r; return NULL; }

    PyObject *slots_dict = PyDict_New();
    if (slots_dict == NULL) return NULL;

    for (uint32_t i = 0; i < n_slots; i++) {
        const char     *slot_name = NULL;
        ds_slot_value_t sv        = {0};
        r = ds_fact_get_slot(fact, i, &slot_name, &sv);
        if (r.status != DS_OK) {
            Py_DECREF(slots_dict);
            *out_r = r;
            return NULL;
        }

        PyObject *py_val = NULL;
        switch (sv.kind) {
        case DS_SLOT_INT:      py_val = PyLong_FromLongLong(sv.v.i);   break;
        case DS_SLOT_FLOAT:    py_val = PyFloat_FromDouble(sv.v.f);    break;
        case DS_SLOT_STRING:   py_val = PyUnicode_FromString(sv.v.s ? sv.v.s : ""); break;
        case DS_SLOT_BOOL:     py_val = PyBool_FromLong((long)sv.v.b); break;
        case DS_SLOT_JSON:     py_val = pyds_json_to_pystr(sv.v.json);break;
        case DS_SLOT_BYTES:
            py_val = PyBytes_FromStringAndSize(
                (const char *)sv.v.bytes.data, (Py_ssize_t)sv.v.bytes.len);
            break;
        case DS_SLOT_FACT_REF: {
            /* The target's id, live or not. A live target is reached through
               the table like any other fact. */
            uint64_t ref = 0;
            r = ds_fact_get_slot_ref_id(fact, i, &ref);
            if (r.status != DS_OK) {
                Py_DECREF(slots_dict);
                *out_r = r;
                return NULL;
            }
            py_val = ref != 0 ? pyds_fact_id(ref) : Py_NewRef(Py_None);
            break;
        }
        default:
            py_val = Py_NewRef(Py_None);                               break;
        }
        if (py_val == NULL) { Py_DECREF(slots_dict); return NULL; }
        if (PyDict_SetItemString(slots_dict, slot_name, py_val) < 0) {
            Py_DECREF(py_val);
            Py_DECREF(slots_dict);
            return NULL;
        }
        Py_DECREF(py_val);
    }
    return slots_dict;
}

/* pyds.Engine.decode_fact_body's primitive: a recorded FactAssert or FactEmit
   body decoded by ds_rfcs_decode_fact_body against the engine's schema called
   `schema_name`, as {slot: value} with the values pyds_fact_slots gives. None
   for a name the engine has no schema by, which pyds raises as KeyError.

   A schema with a fact-ref slot is a ValueError before libds is asked: its
   recorded handle means something only to the stream's own reader
   ([RFCS.6.3]), and ds_rfcs_decode_fact_body refuses it for that reason. */
static PyObject *
PydsEngine_decode_fact_body(PydsEngineObject *self, PyObject *args)
{
    const char *schema_name;
    Py_buffer view;
    if (!PyArg_ParseTuple(args, "sy*", &schema_name, &view)) {
        return NULL;
    }
    PyObject *out = NULL;
    PyObject *slots = NULL;
    ds_slot_value_t *values = NULL;
    char *scratch = NULL;
    size_t scratch_cap = 0;
    uint32_t got = 0;
    uint32_t n = 0;
    const ds_schema_t *schema = NULL;
    ds_result_t r;

    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        goto done;
    }
    r = ds_engine_schema_find(self->engine, schema_name, &schema);
    if (r.status != DS_OK) {
        pyds_raise_from_result(r);
        goto done;
    }
    if (schema == NULL) {
        out = Py_NewRef(Py_None);
        goto done;
    }
    r = ds_schema_get_slot_count(schema, &n);
    if (r.status != DS_OK) {
        pyds_raise_from_result(r);
        goto done;
    }
    for (uint32_t i = 0; i < n; i++) {
        ds_slot_desc_t d;
        r = ds_schema_get_slot(schema, i, &d);
        if (r.status != DS_OK) {
            pyds_raise_from_result(r);
            goto done;
        }
        if (d.type == DS_SLOT_TYPE_SCHEMA) {
            PyErr_Format(PyExc_ValueError,
                         "%s.%s is a fact reference: its recorded handle means "
                         "something only to the stream's own reader",
                         schema_name, d.name ? d.name : "?");
            goto done;
        }
    }
    /* libds's sizing: a value per slot, and the body's bytes plus a NUL per
       slot for the strings it copies out. */
    values = PyMem_Calloc(n ? n : 1, sizeof *values);
    scratch_cap = (size_t)view.len + (size_t)n + 1;
    scratch = PyMem_Malloc(scratch_cap);
    if (values == NULL || scratch == NULL) {
        PyErr_NoMemory();
        goto done;
    }
    r = ds_rfcs_decode_fact_body(schema, (const uint8_t *)view.buf, (size_t)view.len,
                                 values, n, scratch, scratch_cap, &got);
    if (r.status != DS_OK) {
        got = 0;    /* the decoder frees what it allocated on an error */
        pyds_raise_from_result(r);
        goto done;
    }
    slots = PyDict_New();
    if (slots == NULL) {
        goto done;
    }
    for (uint32_t i = 0; i < got; i++) {
        ds_slot_desc_t d;
        r = ds_schema_get_slot(schema, i, &d);
        if (r.status != DS_OK) {
            Py_DECREF(slots);
            pyds_raise_from_result(r);
            goto done;
        }
        const ds_slot_value_t *sv = &values[i];
        PyObject *py_val;
        switch (sv->kind) {
        case DS_SLOT_INT:    py_val = PyLong_FromLongLong(sv->v.i);   break;
        case DS_SLOT_FLOAT:  py_val = PyFloat_FromDouble(sv->v.f);    break;
        case DS_SLOT_STRING: py_val = PyUnicode_FromString(sv->v.s ? sv->v.s : ""); break;
        case DS_SLOT_BOOL:   py_val = PyBool_FromLong((long)sv->v.b); break;
        case DS_SLOT_JSON:   py_val = pyds_json_to_pystr(sv->v.json); break;
        case DS_SLOT_BYTES:
            py_val = PyBytes_FromStringAndSize((const char *)sv->v.bytes.data,
                                               (Py_ssize_t)sv->v.bytes.len);
            break;
        default:             py_val = Py_NewRef(Py_None);             break;
        }
        if (py_val == NULL
                || PyDict_SetItemString(slots, d.name ? d.name : "", py_val) < 0) {
            Py_XDECREF(py_val);
            Py_DECREF(slots);
            goto done;
        }
        Py_DECREF(py_val);
    }
    out = slots;

done:
    /* Json trees are the decoder's allocations, the caller's to free. */
    for (uint32_t i = 0; i < got; i++) {
        if (values[i].kind == DS_SLOT_JSON && values[i].v.json != NULL) {
            ds_json_free(values[i].v.json);
        }
    }
    PyMem_Free(values);
    PyMem_Free(scratch);
    PyBuffer_Release(&view);
    return out;
}

/*
 * The primitives behind pyds.Engine.facts (pyds/engine.py), which builds the
 * Mapping view and the pyds.Fact values from them.
 *
 * A fact crosses as one record,
 *
 *   (FactId, schema name, {slot: value}, asserted_ns, ttl_deadline_ns)
 *
 * with the slot decoding above and libds's own numbers: ttl_deadline_ns is 0
 * for a fact with no deadline, and pyds.Fact reads that as None.
 *
 * TWO WAYS IN, ON PURPOSE. _fact and _fact_live reach one fact through the
 * live-fact table, which the stream maintains. _fact_ids and _facts walk the
 * engine's own working memory through ds_engine_for_each_fact (libds.h) and
 * never consult the stream, so a reader can hold the two against each other.
 */

/* One fact's record. On a libds failure the exception is raised from it. */
static PyObject *
pyds_fact_record(const ds_fact_t *fact)
{
    const char *schema_name = NULL;
    ds_result_t r = DS_OK_R;
    PyObject *slots = pyds_fact_slots(fact, &schema_name, &r);
    if (slots == NULL) {
        return r.status != DS_OK ? pyds_raise_from_result(r) : NULL;
    }
    uint64_t asserted_ns = 0;
    uint64_t deadline_ns = 0;
    r = ds_fact_get_asserted_ns(fact, &asserted_ns);
    if (r.status == DS_OK) {
        r = ds_fact_get_ttl_deadline_ns(fact, &deadline_ns);
    }
    if (r.status != DS_OK) {
        Py_DECREF(slots);
        return pyds_raise_from_result(r);
    }
    PyObject *fid = pyds_fact_id_of(fact);
    if (fid == NULL) {
        Py_DECREF(slots);
        return NULL;
    }
    /* "N" steals each reference, including on failure. */
    return Py_BuildValue("(NsNKK)", fid, schema_name, slots,
                         (unsigned long long)asserted_ns,
                         (unsigned long long)deadline_ns);
}

/* The schema a walk is restricted to: NULL for None, which walks every
   fact. A name the engine does not know raises ValueError -- a typo would
   otherwise read as an empty relation -- and *out_ok is 0. */
static const ds_schema_t *
pyds_walk_schema(PydsEngineObject *self, PyObject *arg, int *out_ok)
{
    *out_ok = 0;
    if (arg == Py_None) {
        *out_ok = 1;
        return NULL;
    }
    if (!PyUnicode_Check(arg)) {
        PyObject *tn = pyds_type_name(arg);
        if (tn != NULL) {
            PyErr_Format(PyExc_TypeError, "a schema is named by a str, not %U", tn);
            Py_DECREF(tn);
        }
        return NULL;
    }
    const char *name = PyUnicode_AsUTF8AndSize(arg, NULL);   /* see schema_find */
    if (name == NULL) {
        return NULL;
    }
    const ds_schema_t *schema = NULL;
    ds_result_t r = ds_engine_schema_find(self->engine, name, &schema);
    if (r.status != DS_OK) {
        (void)pyds_raise_from_result(r);
        return NULL;
    }
    if (schema == NULL) {
        PyErr_Format(PyExc_ValueError, "no schema named %R", arg);
        return NULL;
    }
    *out_ok = 1;
    return schema;
}

/* The walk's visitor reads only: the walk borrows each fact, and mutating
   the engine inside it would invalidate working memory mid-walk (libds.h
   says so). Order is the walk's, hash-keyed and unspecified; pyds sorts. */
typedef struct {
    PyObject *list;
    int       records;  /* 1: whole records; 0: FactIds only */
    int       failed;   /* a Python exception is set; the ds_result_t carries it out */
} pyds_facts_walk_t;

static ds_result_t
pyds_facts_visitor(const ds_fact_t *fact, void *user)
{
    pyds_facts_walk_t *w = (pyds_facts_walk_t *)user;
    PyObject *item = w->records ? pyds_fact_record(fact)
                                : pyds_fact_id_of(fact);
    if (item == NULL) {
        w->failed = 1;
        return DS_ERR_R(DS_ERR_INTERNAL, "a fact could not be read out");
    }
    int rc = PyList_Append(w->list, item);
    Py_DECREF(item);
    if (rc < 0) {
        w->failed = 1;
        return DS_ERR_R(DS_ERR_INTERNAL, "a fact could not be read out");
    }
    return DS_OK_R;
}

static PyObject *
pyds_facts_walk(PydsEngineObject *self, PyObject *arg, int records)
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    int ok = 0;
    const ds_schema_t *schema = pyds_walk_schema(self, arg, &ok);
    if (!ok) {
        return NULL;
    }
    pyds_facts_walk_t w = { PyList_New(0), records, 0 };
    if (w.list == NULL) {
        return NULL;
    }
    ds_result_t r = ds_engine_for_each_fact(self->engine, schema,
                                            pyds_facts_visitor, &w);
    if (w.failed) {
        Py_DECREF(w.list);
        return NULL;
    }
    if (r.status != DS_OK) {
        Py_DECREF(w.list);
        return pyds_raise_from_result(r);
    }
    return w.list;
}

/* _fact_ids(schema) -> list[FactId]: the walk's ids, one schema's or (None)
   all of them. */
static PyObject *
PydsEngine_fact_ids(PydsEngineObject *self, PyObject *arg)
{
    return pyds_facts_walk(self, arg, 0);
}

/* _facts(schema) -> list[record]: the walk's facts, one schema's or (None)
   all of them. */
static PyObject *
PydsEngine_facts(PydsEngineObject *self, PyObject *arg)
{
    return pyds_facts_walk(self, arg, 1);
}

/* _fact(fact_id) -> record, through the live-fact table. KeyError for a fact
   that is not live; inside a stream callback for that fact's
   retract, it still is. */
static PyObject *
PydsEngine_fact(PydsEngineObject *self, PyObject *arg)
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_fact_t *fact = pyds_live_find(self, arg);
    if (fact == NULL) {
        return NULL;
    }
    return pyds_fact_record(fact);
}

/* _fact_live(fact_id) -> bool, through the live-fact table, decoding
   nothing. */
static PyObject *
PydsEngine_fact_live(PydsEngineObject *self, PyObject *arg)
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (pyds_live_find(self, arg) != NULL) {
        Py_RETURN_TRUE;
    }
    if (PyErr_ExceptionMatches(PyExc_KeyError)) {
        PyErr_Clear();
        Py_RETURN_FALSE;
    }
    return NULL;
}

/* _justifiers(fact_id: int) -> list[{"timetag": int, "rule_name": str}]
 *
 * One entry per activation that logically supports fact_id; empty for a
 * fact nothing supports, and for an unknown id, which pyds.Engine.debug
 * refuses before it gets here. Only meaningful while paused (valid TMS
 * state). */
static PyObject *
PydsEngine_get_justifiers(PydsEngineObject *self, PyObject *args)
{
    uint64_t fact_id = 0;
    if (!PyArg_ParseTuple(args, "O&", pyds_u64_arg, &fact_id)) return NULL;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    int64_t   *timetags   = NULL;
    char     **rule_names = NULL;
    uint32_t   count      = 0;
    ds_result_t r = ds_engine_get_justifiers(
        self->engine, (uint64_t)fact_id,
        &timetags, &rule_names, &count);
    if (r.status != DS_OK) return pyds_raise_from_result(r);

    /* All three releases are ds_free, never libc free ([IALC.4.3]):
       libds allocated these with ds_malloc, which an integrator's strong
       allocator override ([IALC.5.1]) or a DS_ALLOC_MACRO build makes a
       different allocator from libc's. */
    PyObject *list = PyList_New((Py_ssize_t)count);
    if (!list) {
        for (uint32_t i = 0; i < count; i++) ds_free(rule_names[i]);
        ds_free(timetags);
        ds_free(rule_names);
        return NULL;
    }
    for (uint32_t i = 0; i < count; i++) {
        PyObject *entry = PyDict_New();
        if (!entry) goto fail;
        PyObject *tt = PyLong_FromLongLong(timetags[i]);
        PyObject *rn = PyUnicode_FromString(rule_names[i] ? rule_names[i] : "");
        if (!tt || !rn || PyDict_SetItemString(entry, "timetag", tt) < 0
                       || PyDict_SetItemString(entry, "rule_name", rn) < 0) {
            Py_XDECREF(tt); Py_XDECREF(rn); Py_DECREF(entry);
            goto fail;
        }
        Py_DECREF(tt); Py_DECREF(rn);
        PyList_SetItem(list, (Py_ssize_t)i, entry);
    }
    for (uint32_t i = 0; i < count; i++) ds_free(rule_names[i]);
    ds_free(timetags);
    ds_free(rule_names);
    return list;

fail:
    Py_DECREF(list);
    for (uint32_t i = 0; i < count; i++) ds_free(rule_names[i]);
    ds_free(timetags);
    ds_free(rule_names);
    return NULL;
}

/* _rete_network(rule_filter=None, include_occupancy=False)
 *   -> {"nodes": [{id,kind,label,filter,occupancy,is_negative},...],
 *       "edges": [{from_id,to_id},...]}
 */
/* THE THREE DEBUG READERS FAIL WHOLE. libds walks and calls back with
   void callbacks, so a collector cannot stop the walk: on the first failure it
   records it and ignores the rest, and the method returns NULL with that
   exception rather than the part it had built. Under memory pressure a
   network with fewer nodes, or an activation over fewer facts, reads exactly
   like a complete answer -- and memory pressure is when these get used. */
static PyObject *
pyds_str(const char *s)
{
    return PyUnicode_FromString(s ? s : "");
}

typedef struct { PyObject *nodes; PyObject *edges; int failed; } ReteNetCtx;

static void rete_node_cb(const char *id, const char *kind, const char *label,
                            const char *filter, uint32_t occupancy,
                            bool is_negative, void *user) {
    ReteNetCtx *ctx = (ReteNetCtx *)user;
    if (ctx->failed) return;
    PyObject *d = PyDict_New();
    if (d == NULL
        || pyds_dict_set_steal(d, "id", pyds_str(id)) < 0
        || pyds_dict_set_steal(d, "kind", pyds_str(kind)) < 0
        || pyds_dict_set_steal(d, "label", pyds_str(label)) < 0
        || pyds_dict_set_steal(d, "filter", pyds_str(filter)) < 0
        || pyds_dict_set_steal(d, "occupancy", occupancy == UINT32_MAX
                                    ? Py_NewRef(Py_None)
                                    : PyLong_FromUnsignedLong(occupancy)) < 0
        || pyds_dict_set_steal(d, "is_negative", PyBool_FromLong(is_negative)) < 0
        || PyList_Append(ctx->nodes, d) < 0) {
        Py_XDECREF(d);
        ctx->failed = 1;
        return;
    }
    Py_DECREF(d);
}
static void rete_edge_cb(const char *from_id, const char *to_id, void *user) {
    ReteNetCtx *ctx = (ReteNetCtx *)user;
    if (ctx->failed) return;
    PyObject *d = PyDict_New();
    if (d == NULL
        || pyds_dict_set_steal(d, "from_id", pyds_str(from_id)) < 0
        || pyds_dict_set_steal(d, "to_id", pyds_str(to_id)) < 0
        || PyList_Append(ctx->edges, d) < 0) {
        Py_XDECREF(d);
        ctx->failed = 1;
        return;
    }
    Py_DECREF(d);
}
static PyObject *
PydsEngine_rete_network(PydsEngineObject *self, PyObject *args, PyObject *kw)
{
    const char *rule_filter = NULL;
    int include_occ = 0;
    static char *kwlist[] = {"rule_filter", "include_occupancy", NULL};
    if (!PyArg_ParseTupleAndKeywords(args, kw, "|zi", kwlist,
                                      &rule_filter, &include_occ)) return NULL;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ReteNetCtx ctx = { PyList_New(0), PyList_New(0), 0 };
    PyObject *result = NULL;
    if (ctx.nodes == NULL || ctx.edges == NULL) goto done;
    ds_result_t r = ds_engine_rete_network(
        self->engine, rule_filter, (bool)include_occ,
        rete_node_cb, &ctx, rete_edge_cb, &ctx);
    if (ctx.failed) goto done;
    if (r.status != DS_OK) { (void)pyds_raise_from_result(r); goto done; }
    result = PyDict_New();
    if (result != NULL
        && (PyDict_SetItemString(result, "nodes", ctx.nodes) < 0
            || PyDict_SetItemString(result, "edges", ctx.edges) < 0)) {
        Py_CLEAR(result);
    }
done:
    Py_XDECREF(ctx.nodes);
    Py_XDECREF(ctx.edges);
    return result;
}

/* ── RDAP1c callbacks and method ── */

/* One list, and whether building it failed: the trace and refraction walks. */
typedef struct { PyObject *list; int failed; } pyds_collect_t;

static void trace_cb(const char *nid, const char *nk,
                       const char *res, const char *det, void *user)
{
    pyds_collect_t *c = (pyds_collect_t *)user;
    if (c->failed) return;
    PyObject *d = PyDict_New();
    if (d == NULL
        || pyds_dict_set_steal(d, "node_id", pyds_str(nid)) < 0
        || pyds_dict_set_steal(d, "node_kind", pyds_str(nk)) < 0
        || pyds_dict_set_steal(d, "result", pyds_str(res)) < 0
        || pyds_dict_set_steal(d, "detail", pyds_str(det)) < 0
        || PyList_Append(c->list, d) < 0) {
        Py_XDECREF(d);
        c->failed = 1;
        return;
    }
    Py_DECREF(d);
}

static PyObject *
PydsEngine_rete_match_trace(PydsEngineObject *self, PyObject *args)
{
    uint64_t fact_id = 0;
    if (!PyArg_ParseTuple(args, "O&", pyds_u64_arg, &fact_id)) return NULL;
    if (!self->engine) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    pyds_collect_t c = { PyList_New(0), 0 };
    if (c.list == NULL) return NULL;
    ds_result_t r = ds_engine_rete_match_trace(
        self->engine, fact_id, trace_cb, &c);
    if (c.failed) { Py_DECREF(c.list); return NULL; }
    if (r.status != DS_OK) { Py_DECREF(c.list); return pyds_raise_from_result(r); }
    return c.list;
}

/* ── RDAP1e callbacks and method ── */

static void refract_cb(const char *rn, const char *reason, const char *det,
                         const uint64_t *fids, uint32_t fcnt, void *user)
{
    pyds_collect_t *c = (pyds_collect_t *)user;
    if (c->failed) return;
    PyObject *fl = PyList_New((Py_ssize_t)fcnt);
    if (fl != NULL) {
        for (uint32_t i = 0; i < fcnt; i++) {
            /* Every fact an entry names is live ([NDBG.4.3]). */
            PyObject *id = pyds_fact_id(fids[i]);
            if (id == NULL) { Py_CLEAR(fl); break; }
            PyList_SetItem(fl, (Py_ssize_t)i, id);   /* steals id */
        }
    }
    PyObject *d = fl != NULL ? PyDict_New() : NULL;
    if (d == NULL
        || pyds_dict_set_steal(d, "rule_name", pyds_str(rn)) < 0
        || pyds_dict_set_steal(d, "reason", pyds_str(reason)) < 0
        || pyds_dict_set_steal(d, "detail", pyds_str(det)) < 0
        || pyds_dict_set_steal(d, "fact_ids", Py_NewRef(fl)) < 0
        || PyList_Append(c->list, d) < 0) {
        Py_XDECREF(fl);
        Py_XDECREF(d);
        c->failed = 1;
        return;
    }
    Py_DECREF(fl);
    Py_DECREF(d);
}

static PyObject *
PydsEngine_refracted_activations(PydsEngineObject *self, PyObject *args)
{
    const char *rule_filter = NULL;
    if (!PyArg_ParseTuple(args, "|z", &rule_filter)) return NULL;
    if (!self->engine) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    pyds_collect_t c = { PyList_New(0), 0 };
    if (c.list == NULL) return NULL;
    ds_result_t r = ds_engine_refracted_activations(
        self->engine, rule_filter, refract_cb, &c);
    if (c.failed) { Py_DECREF(c.list); return NULL; }
    if (r.status != DS_OK) { Py_DECREF(c.list); return pyds_raise_from_result(r); }
    return c.list;
}

/* No _register_schema: a schema reaches the engine from a compiled artefact
   and in no other way ([NFCT.1.1]). */

PyDoc_STRVAR(pyds_engine_clone_doc,
"clone($self, /)\n"
"--\n"
"\n"
"Return an independent copy of this engine.\n"
"\n"
"The copy holds the whole runtime state: working memory, the series, the\n"
"cache, truth maintenance, the agenda and every counter. Driving the two\n"
"with the same input gives identical streams. They share no mutable state\n"
"and may be closed in either order.\n"
"\n"
"The copy has no callbacks: set those it needs before pumping it.");

static PyObject *
PydsEngine_clone(PydsEngineObject *self, PyObject *Py_UNUSED(ignored))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    ds_engine_t *cloned = NULL;
    ds_result_t r = ds_engine_clone(self->engine, &cloned);
    if (r.status != DS_OK) return pyds_raise_from_result(r);

    /* Wrap the cloned ds_engine_t in a fresh Engine (bypassing __init__, which
       would ds_engine_new a blank engine). libds starts the clone with none of
       the source's callbacks ([NLFC.8.3]), and tp_alloc zero-inits the object,
       so its Python callback slots start empty to match. */
    PyTypeObject *tp = Py_TYPE((PyObject *)self);
    allocfunc tp_alloc = (allocfunc)PyType_GetSlot(tp, Py_tp_alloc);   /* PY.16 */
    PydsEngineObject *obj = (PydsEngineObject *)tp_alloc(tp, 0);
    if (obj == NULL) { (void)ds_engine_free(cloned); return NULL; }
    obj->engine = cloned;
    /* The clone's facts are its own: same ids, other pointers. Its
       table is built here from the clone's working memory, and its own
       observer keeps it from then on. */
    obj->live = PyDict_New();
    if (obj->live == NULL) { Py_DECREF((PyObject *)obj); return NULL; }
    r = ds_engine_set_stream_callback(cloned, pyds_on_event, obj);
    if (r.status != DS_OK) { Py_DECREF((PyObject *)obj); return pyds_raise_from_result(r); }
    pyds_live_refresh(obj);
    return (PyObject *)obj;
}

/* ---- RFCS replay (PYRFCS1 / PYRFCS3) --------------------------- */

/* Feed one bytes-like object to the replay ctx. Returns 0, or -1 with a
 * Python exception set. *out_len (optional) receives the byte count, which
 * the read() loop uses to detect EOF — an empty read is the only end signal
 * a file object gives. */
/* After a replay, on every path. ds_rfcs_replay_begin puts
 * the replay's own compare recorder in the engine's stream slot, and
 * ds_rfcs_replay_finish leaves the slot empty: pyds's observer goes back,
 * or the Python stream callback and any recording silently hear nothing
 * more. The replay's facts went to that recorder, not to the table, so the
 * table is rebuilt from working memory here. */
static void pyds_after_replay(PydsEngineObject *self)
{
    (void)ds_engine_set_stream_callback(self->engine, pyds_on_event, self);
    pyds_live_refresh(self);
}

static int replay_feed_obj(ds_rfcs_replay_ctx_t *ctx, PyObject *obj,
                           Py_ssize_t *out_len)
{
    Py_buffer view;
    if (PyObject_GetBuffer(obj, &view, PyBUF_SIMPLE) != 0) {
        PyErr_SetString(PyExc_TypeError,
                        "replay: chunks must be bytes-like");
        return -1;
    }
    Py_ssize_t n  = view.len;
    int        rc = 0;
    if (n > 0) {
        ds_result_t r = ds_rfcs_replay_feed(ctx, (const uint8_t *)view.buf,
                                            (size_t)n);
        if (r.status != DS_OK) {
            (void)pyds_raise_from_result(r);
            rc = -1;
        }
    }
    PyBuffer_Release(&view);
    if (out_len) *out_len = n;
    return rc;
}

/* _replay(stream, chunk_size) -> dict; pyds.Engine.replay makes it a
 * pyds.ReplayResult.
 *
 * Replay an RFCS fact stream into this engine through the C codec
 * ([LFST.9.6]): inputs delivered, rules re-fired, every re-derived compare
 * atom byte-checked against the record.
 *
 * There is no `hydrate=`: rebuilding working memory without running the
 * engine is not an operation ([LFST.9.6]). A caller that wants the
 * recorded facts without replaying reads the trace with pyds.atoms.
 *
 * `stream` is bytes, a file object (anything with read(n)), or an iterable of
 * bytes-like chunks. It is FED, never held: chunks go straight into
 * ds_rfcs_replay_feed and are released as soon as they are consumed, so a
 * recording far larger than memory replays fine. [LFST.12.4] sizes a single
 * tier's daily recording at 4GB-40GB, which is the whole reason this takes a
 * stream rather than a buffer.
 *
 * PYRFCS3 removed a `replay_bufs` list that used to retain the stream and a
 * 2*len decode arena, per call, for the engine's lifetime — the engine
 * borrowed replayed facts' String/Bytes slot bytes out of both, so nothing
 * could be released without risking a use-after-free on slot readback. The
 * engine now copies those slots into its intern at assert, so there is
 * nothing to retain and the method has no lifetime story left.
 */
static PyObject *
PydsEngine_replay_stream(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = { "stream", "chunk_size", NULL };
    PyObject   *src        = NULL;
    Py_ssize_t  chunk_size = 65536;

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "O|n", kwlist,
                                     &src, &chunk_size)) {
        return NULL;
    }
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (chunk_size <= 0) {
        /* pyds.Engine.replay checks first; this keeps the primitive honest. */
        PyErr_SetString(PyExc_ValueError, "chunk_size must be at least 1");
        return NULL;
    }

    ds_rfcs_replay_ctx_t *ctx = NULL;
    ds_result_t r = ds_rfcs_replay_begin(self->engine, NULL, &ctx);
    if (r.status != DS_OK) {
        pyds_after_replay(self);
        return pyds_raise_from_result(r);
    }

    /* A bytes-like argument is the whole stream, so a partial trailing atom
       is the caller's slice being short, and [RFCS.19.2] lets this reader
       refuse it. A file or an iterable may be a recording still being
       written: its partial tail is end-of-stream, reported as `tail_bytes`. */
    const int whole_extent = PyObject_CheckBuffer(src);

    if (whole_extent) {
        /* One buffer — still fed through, never retained. */
        if (replay_feed_obj(ctx, src, NULL) != 0) goto py_error;
    } else if (PyObject_HasAttrString(src, "read")) {
        /* A file, a socket makefile, a BytesIO: read to EOF. */
        for (;;) {
            PyObject *chunk = PyObject_CallMethod(src, "read", "n", chunk_size);
            if (chunk == NULL) goto py_error;
            Py_ssize_t got = 0;
            int rc = replay_feed_obj(ctx, chunk, &got);
            Py_DECREF(chunk);
            if (rc != 0) goto py_error;
            if (got == 0) break;                       /* EOF */
        }
    } else {
        /* Any iterable of bytes-like chunks. */
        PyObject *it = PyObject_GetIter(src);
        if (it == NULL) {
            PyErr_SetString(PyExc_TypeError,
                            "replay: expected bytes, a file object, or "
                            "an iterable of bytes-like chunks");
            goto py_error;
        }
        PyObject *chunk;
        while ((chunk = PyIter_Next(it)) != NULL) {
            int rc = replay_feed_obj(ctx, chunk, NULL);
            Py_DECREF(chunk);
            if (rc != 0) { Py_DECREF(it); goto py_error; }
        }
        Py_DECREF(it);
        if (PyErr_Occurred()) goto py_error;
    }

    ds_rfcs_replay_result_t res;
    memset(&res, 0, sizeof(res));
    r = ds_rfcs_replay_finish(ctx, &res);   /* destroys ctx either way */
    pyds_after_replay(self);
    if (r.status == DS_OK && whole_extent && res.tail_bytes != 0) {
        r = DS_ERR_R(DS_ERR_PARSE, "replay: stream ends mid-atom (truncated)");
    }
    if (cb_settle(self, r) < 0) {
        return NULL;
    }

    return Py_BuildValue(
        "{s:K,s:K,s:K,s:K,s:K,s:K,s:K,s:O,s:K}",
        "asserts",         (unsigned long long)res.asserts,
        "retracts",        (unsigned long long)res.retracts,
        "clocks",          (unsigned long long)res.clocks,
        "rule_fires",      (unsigned long long)res.rule_fires,
        "calls",           (unsigned long long)res.calls,
        "withdrawals",     (unsigned long long)res.withdrawals,
        "skipped",         (unsigned long long)res.skipped,
        "header_verified", res.header_verified ? Py_True : Py_False,
        "tail_bytes",      (unsigned long long)res.tail_bytes);

py_error:
    /* finish() always destroys the ctx; a Python exception is already set, so
       whatever it reports about the partial stream is not the story to tell. */
    (void)ds_rfcs_replay_finish(ctx, NULL);
    pyds_after_replay(self);
    cb_drop(self);
    return NULL;
}

/* RFCSXCODEC1 — _record_start(path, flush) / _record_stop(), behind
 * pyds.Engine.record and pyds.Recording.close: libds's own recorder, the one
 * writer of a stream pyds has.
 *
 * The recording is written straight to a file rather than through a Python
 * sink callback: the sink runs inside the engine pump, and a Python callable
 * there would need the GIL on a path that must never abort the pump. fwrite
 * has no such requirement.
 */
static ds_result_t
pyds_record_sink(const uint8_t *bytes, size_t len, void *user)
{
    PydsEngineObject *self = (PydsEngineObject *)user;
    FILE *f = self ? self->recfile : NULL;
    if (f == NULL) {
        return (ds_result_t){ DS_ERR_INVAL, "record sink: file closed" };
    }
    if (len > 0 && fwrite(bytes, 1, len, f) != len) {
        return (ds_result_t){ DS_ERR_IO, "record sink: short write" };
    }
    /* RECTEE1 — flush=True makes each atom readable from the file as soon as
       it is written, so a reader can follow a recording still in progress. */
    if (self->recflush && fflush(f) != 0) {
        return (ds_result_t){ DS_ERR_IO, "record sink: flush failed" };
    }
    return DS_OK_R;
}

static PyObject *
PydsEngine_record_to(PydsEngineObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = { "path", "flush", NULL };
    const char *path = NULL;
    int flush = 0;
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "s|p", kwlist, &path, &flush))
        return NULL;
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    if (self->recfile != NULL) {
        PyErr_SetString(PyExc_RuntimeError,
            "already recording: close the engine's Recording first");
        return NULL;
    }

    uint8_t *buf = PyMem_Malloc(PYDS_RECBUF);
    if (buf == NULL) return PyErr_NoMemory();

    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        PyMem_Free(buf);
        PyErr_SetFromErrnoWithFilename(PyExc_OSError, path);
        return NULL;
    }

    /* Publish the state the sink and teardown read BEFORE arming the
       recorder: ds_rfcs_record_begin emits the StreamHeader synchronously,
       so the sink fires inside this call. */
    self->recbuf   = buf;
    self->recfile  = f;
    self->recflush = flush;

    ds_result_t r = ds_rfcs_record_begin(self->engine, &self->rec,
                                         pyds_record_sink, self,
                                         buf, PYDS_RECBUF);
    if (r.status != DS_OK) {
        self->recfile  = NULL;
        self->recbuf   = NULL;
        self->recflush = 0;
        fclose(f);
        PyMem_Free(buf);
        memset(&self->rec, 0, sizeof(self->rec));
        return pyds_raise_from_result(r);
    }
    /* RECTEE1 — ds_rfcs_record_begin installed nothing: with `recfile` set,
       pyds_on_event hands each event to the recorder, then to any Python
       stream callback. */
    Py_RETURN_NONE;
}

static PyObject *
PydsEngine_stop_recording(PydsEngineObject *self, PyObject *Py_UNUSED(ignored))
{
    if (self->recfile == NULL) Py_RETURN_NONE;   /* idempotent */

    int close_errno = 0;
    ds_result_t last = pyds_engine_stop_recording(self, &close_errno);

    /* Report the recorder's own failure ahead of the close: a short write or a
       failed encode says the recording is WRONG, while a failed close only
       says the last flush is in doubt. */
    if (last.status != DS_OK) return pyds_raise_from_result(last);
    if (close_errno != 0) {
        errno = close_errno;
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
    Py_RETURN_NONE;
}

PyDoc_STRVAR(pyds_engine_load_dsc_doc,
"load_dsc($self, dsc, /)\n"
"--\n"
"\n"
"Load a compiled ``.dsc`` artefact into the engine.\n"
"\n"
"``dsc`` is any bytes-like object. An artefact the engine refuses raises\n"
"the ``pyds.Error`` for libds's status, whose ``status`` says why, and\n"
"spends the engine (RDSC.9.8): ``halted`` reads 0, and every later call but\n"
"``halted``, ``platform_signature``, ``session_header`` and ``close``\n"
"raises ``Status.ENGINE_HALTED``. Another load takes a new ``Engine``.");

PyDoc_STRVAR(pyds_engine_assert_doc,
"assert_($self, schema, /, **slots)\n"
"--\n"
"\n"
"Assert a fact of ``schema`` and return its ``FactId``.\n"
"\n"
"Each keyword names a slot; a nullable slot may be left out, and holds no\n"
"value. The engine assigns the id: ids increase and are never reused. A\n"
"String slot takes a ``str``, or ``bytes`` or ``bytearray`` as its text's\n"
"UTF-8, handed to libds unchanged.\n"
"\n"
"Raises ``KeyError`` for a schema the engine does not know; ``TypeError``\n"
"for a slot missing or unknown; ``TypeError``, ``ValueError`` or\n"
"``OverflowError`` for a value its slot does not admit; and the\n"
"``pyds.Error`` for libds's status when the engine refuses the fact:\n"
"``Status.ENCODING`` for String octets that are not well-formed UTF-8.");

PyDoc_STRVAR(pyds_engine_assert_external_doc,
"assert_external($self, data, /)\n"
"--\n"
"\n"
"Assert a fact another engine encoded, from its FactExternal bytes.\n"
"\n"
"``data`` is bytes-like, or a ``pyds.EncodedFact``, whose ``data`` is\n"
"taken. The fact's references resolve against this engine's working\n"
"memory: one equal to a live fact is that fact. Returns None; what was\n"
"asserted is in the stream.\n"
"\n"
"The whole record is refused, with nothing asserted, by the\n"
"``pyds.Error`` for its status: ``InputError`` with ``Status.PARSE``\n"
"for bytes that are not a FactExternal or nest deeper than 16, or with\n"
"``Status.SCHEMA_UNKNOWN`` for a schema this program does not declare;\n"
"``ExecutionError`` with ``Status.SCHEMA_HASH_MISMATCH`` for a schema\n"
"that differs from this program's, or with ``Status.FACT_REF_CONFLICT``\n"
"for a reference whose key a live fact holds with other values.");

PyDoc_STRVAR(pyds_engine_retract_doc,
"retract($self, fact_id, /)\n"
"--\n"
"\n"
"Remove the live fact ``fact_id`` names.\n"
"\n"
"``fact_id`` is a ``FactId``, or any integer but a bool. Raises\n"
"``KeyError`` for a fact that is not live: retracted, expired, superseded\n"
"or never asserted.");

PyDoc_STRVAR(pyds_engine_set_call_callback_doc,
"set_call_callback($self, callback, /)\n"
"--\n"
"\n"
"Call ``callback(request)`` for each call a rule issues; None removes it.\n"
"\n"
"``request`` is a dict: ``service`` (str), ``correlation`` (str: the\n"
"call's ``as`` value, or the one generated for a call with none),\n"
"``args`` (each kwarg's value by name: int,\n"
"float, str, bool, bytes or None, a Json value as its canonical text, or\n"
"a ``pyds.EncodedFact`` for a fact), ``timetag`` (int) and ``rule_name``\n"
"(str, or None outside a firing). The answer is a fact of the service's\n"
"response schema, asserted later.");

PyDoc_STRVAR(pyds_engine_enter_doc,
"__enter__($self, /)\n"
"--\n"
"\n"
"Return the engine, for a ``with`` block.");

PyDoc_STRVAR(pyds_engine_exit_doc,
"__exit__($self, /, *exc_info)\n"
"--\n"
"\n"
"Close the engine at the end of a ``with`` block.\n"
"\n"
"Returns False, so an exception from the block is not suppressed.");

static PyMethodDef PydsEngine_methods[] = {
    { "clone", (PyCFunction)PydsEngine_clone, METH_NOARGS,
      pyds_engine_clone_doc },
    { "load_dsc", (PyCFunction)PydsEngine_load_dsc, METH_VARARGS,
      pyds_engine_load_dsc_doc },
    { "_schema_count", (PyCFunction)PydsEngine_schema_count, METH_NOARGS,
      "_schema_count($self, /)\n--\n\nThe number of schemas; pyds.Engine.schemas reads it." },
    { "_schema_at", (PyCFunction)PydsEngine_schema_at, METH_O,
      "_schema_at($self, index, /)\n--\n\n"
      "The record of the schema at index; pyds.Engine.schemas reads it." },
    { "_schema_find", (PyCFunction)PydsEngine_schema_find, METH_O,
      "_schema_find($self, name, /)\n--\n\n"
      "The record of the schema called name, or None; pyds.Engine.schemas reads it." },
    { "_decode_fact_body", (PyCFunction)PydsEngine_decode_fact_body, METH_VARARGS,
      "_decode_fact_body($self, schema, body, /)\n--\n\n"
      "A recorded fact body as {slot: value}, or None for an unknown schema; "
      "pyds.Engine.decode_fact_body calls it." },
    { "_set_admission", (PyCFunction)PydsEngine_set_admission, METH_VARARGS,
      "_set_admission($self, capability, admission, /)\n--\n\n"
      "Set one capability's admission policy; pyds.Engine.set_admission calls it." },
    { "_ds_source_count", (PyCFunction)PydsEngine_ds_source_count,
      METH_NOARGS,
      "_ds_source_count($self, /)\n--\n\n"
      "The number of the program's source files; "
      "pyds.Engine.sources reads it." },
    { "_ds_source_at", (PyCFunction)PydsEngine_ds_source_at, METH_O,
      "_ds_source_at($self, index, /)\n--\n\n"
      "The record of the source file at index; "
      "pyds.Engine.sources reads it." },
    { "_line_span_count", (PyCFunction)PydsEngine_line_span_count,
      METH_NOARGS,
      "_line_span_count($self, /)\n--\n\n"
      "The number of node source spans; pyds.Engine.line_spans reads it." },
    { "_line_span_at", (PyCFunction)PydsEngine_line_span_at, METH_O,
      "_line_span_at($self, index, /)\n--\n\n"
      "The record of the span at index; pyds.Engine.line_spans reads it." },
    { "_line_span_find", (PyCFunction)PydsEngine_line_span_find, METH_O,
      "_line_span_find($self, node_id, /)\n--\n\n"
      "The record of the span for node_id, or None; "
      "pyds.Engine.line_spans reads it." },
    { "_rule_count", (PyCFunction)PydsEngine_rule_count, METH_NOARGS,
      "_rule_count($self, /)\n--\n\nThe number of rules; pyds.Engine.rules reads it." },
    { "_rule_at", (PyCFunction)PydsEngine_rule_at, METH_O,
      "_rule_at($self, index, /)\n--\n\n"
      "The record of the rule at index; pyds.Engine.rules reads it." },
    { "_rule_find", (PyCFunction)PydsEngine_rule_find, METH_O,
      "_rule_find($self, name, /)\n--\n\n"
      "The record of the rule called name, or None; pyds.Engine.rules reads it." },
    { "assert_", (PyCFunction)PydsEngine_assert_,
      METH_VARARGS | METH_KEYWORDS, pyds_engine_assert_doc },
    { "assert_external", (PyCFunction)PydsEngine_assert_external, METH_O,
      pyds_engine_assert_external_doc },
    { "pump", (PyCFunction)PydsEngine_pump, METH_NOARGS,
      "pump($self, /)\n--\n\n"
      "Run the agenda to exhaustion. Takes no argument: nothing bounds one pump's work." },
    { "_fact_count", (PyCFunction)PydsEngine_fact_count, METH_NOARGS,
      "_fact_count($self, /)\n--\n\n"
      "The number of facts in working memory; len(pyds.Engine.facts) reads it." },
    { "_halted", (PyCFunction)PydsEngine_halted, METH_NOARGS,
      "_halted($self, /)\n--\n\n"
      "The halting fault's number, or None; pyds.Engine.halted reads it." },
    { "_mem", (PyCFunction)PydsEngine_mem, METH_NOARGS,
      "_mem($self, /)\n--\n\nds_engine_mem's fields by name; pyds.Engine.memory_usage reads it." },
    { "_clock_mode", (PyCFunction)PydsEngine_clock_mode, METH_NOARGS,
      "_clock_mode($self, /)\n--\n\n\"live\" or \"mock\"; pyds.Engine.clock reads it." },
    { "_clock_set_mode", (PyCFunction)PydsEngine_clock_set_mode, METH_O,
      "_clock_set_mode($self, mode, /)\n--\n\n"
      "Switch to \"live\" or \"mock\"; pyds.Engine.clock calls it." },
    { "_clock_now", (PyCFunction)PydsEngine_clock_now, METH_NOARGS,
      "_clock_now($self, /)\n--\n\nThe monotonic clock's value; pyds.Engine.clock reads it." },
    { "_clock_set", (PyCFunction)PydsEngine_clock_set, METH_O,
      "_clock_set($self, now_ns, /)\n--\n\n"
      "Set the mock monotonic clock; pyds.Engine.clock calls it." },
    { "_clock_advance", (PyCFunction)PydsEngine_clock_advance, METH_O,
      "_clock_advance($self, delta_ns, /)\n--\n\n"
      "Advance the mock clocks; pyds.Engine.clock calls it." },
    { "_wall_clock_set", (PyCFunction)PydsEngine_wall_clock_set, METH_O,
      "_wall_clock_set($self, utc_ns, /)\n--\n\n"
      "Set the mock wall clock; pyds.Engine.clock calls it." },
    { "_replay", (PyCFunction)PydsEngine_replay_stream, METH_VARARGS | METH_KEYWORDS,
      "_replay($self, stream, chunk_size=65536)\n--\n\n"
      "Replay a stream and return its counters by name; pyds.Engine.replay calls it." },
    { "_record_start", (PyCFunction)PydsEngine_record_to, METH_VARARGS | METH_KEYWORDS,
      "_record_start($self, path, flush=False)\n--\n\n"
      "Start libds's recorder writing path; pyds.Engine.record calls it." },
    { "_record_stop", (PyCFunction)PydsEngine_stop_recording, METH_NOARGS,
      "_record_stop($self, /)\n--\n\n"
      "Stop the recorder and report what it hit; pyds.Recording.close calls it." },
    { "_set_stream_callback", (PyCFunction)PydsEngine_set_stream_callback, METH_O,
      "_set_stream_callback($self, callback, /)\n--\n\n"
      "Call callback(record) for every stream event, a dict; None removes it. "
      "pyds.Engine.on_event sets it." },
    { "set_call_callback", (PyCFunction)PydsEngine_set_call_callback,
      METH_VARARGS, pyds_engine_set_call_callback_doc },
    { "_set_cache_callbacks", (PyCFunction)PydsEngine_set_cache_callbacks,
      METH_VARARGS | METH_KEYWORDS,
      "_set_cache_callbacks($self, /, set_cb=None, delete_cb=None)\n--\n\n"
      "Register both cache callbacks at once; None leaves one unset. "
      "pyds.Engine.on_cache_set and on_cache_delete set them." },
    { "_cache_seed", (PyCFunction)PydsEngine_cache_seed, METH_VARARGS | METH_KEYWORDS,
      "_cache_seed($self, key, value_json, ttl_ns=0)\n--\n\n"
      "Seed the engine-owned cache; pyds.Engine.cache.seed calls it." },
    { "retract", (PyCFunction)PydsEngine_retract, METH_VARARGS,
      pyds_engine_retract_doc },
    { "_set_cache_cap", (PyCFunction)PydsEngine_set_cache_cap, METH_VARARGS | METH_KEYWORDS,
      "_set_cache_cap($self, /, *, cap_keys=0, cap_bytes=0)\n--\n\n"
      "The cache's bounds; pyds.Engine.cache.set_cap calls it." },
    { "_set_log_callback", (PyCFunction)PydsEngine_set_log_callback, METH_O,
      "_set_log_callback($self, callback, /)\n--\n\n"
      "Call callback(record) for every log, a dict; None removes it. "
      "pyds.Engine.on_log sets it." },
    { "_set_metric_callback", (PyCFunction)PydsEngine_set_metric_callback, METH_O,
      "_set_metric_callback($self, callback, /)\n--\n\n"
      "Call callback(record) for every metric, a dict; None removes it. "
      "pyds.Engine.on_metric sets it." },
    { "_platform_signature", (PyCFunction)PydsEngine_platform_signature, METH_NOARGS,
      "_platform_signature($self, /)\n--\n\n"
      "The platform signature's fields by name; pyds.Engine.platform_signature reads it." },
    { "_session_header", (PyCFunction)PydsEngine_session_header, METH_NOARGS,
      "_session_header($self, /)\n--\n\n"
      "The session header's fields by name; pyds.Engine.session_header reads it." },
    { "_fact", (PyCFunction)PydsEngine_fact, METH_O,
      "_fact($self, fact_id, /)\n--\n\n"
      "The record of a live fact, through the live-fact table; pyds.Engine.facts reads it." },
    { "_fact_live", (PyCFunction)PydsEngine_fact_live, METH_O,
      "_fact_live($self, fact_id, /)\n--\n\n"
      "Whether a fact is live, through the live-fact table; pyds.Engine.facts reads it." },
    { "_fact_ids", (PyCFunction)PydsEngine_fact_ids, METH_O,
      "_fact_ids($self, schema, /)\n--\n\n"
      "The ids working memory holds, one schema's or (None) all; pyds.Engine.facts reads it." },
    { "_facts", (PyCFunction)PydsEngine_facts, METH_O,
      "_facts($self, schema, /)\n--\n\n"
      "The records working memory holds, one schema's or (None) all; "
      "pyds.Engine.facts reads it." },
    { "_justifiers", (PyCFunction)PydsEngine_get_justifiers, METH_VARARGS,
      "_justifiers($self, fact_id, /)\n--\n\n"
      "The activations supporting a fact, as records; pyds.Engine.debug.justifiers reads it." },
    { "_rete_network", (PyCFunction)PydsEngine_rete_network, METH_VARARGS | METH_KEYWORDS,
      "_rete_network($self, rule_filter=None, include_occupancy=False)\n--\n\n"
      "The network's nodes and edges, as records; pyds.Engine.debug.network reads it." },
    { "_rete_match_trace", (PyCFunction)PydsEngine_rete_match_trace, METH_VARARGS,
      "_rete_match_trace($self, fact_id, /)\n--\n\n"
      "A fact's alpha-node trace, as records; pyds.Engine.debug.match_trace reads it." },
    { "_refracted_activations", (PyCFunction)PydsEngine_refracted_activations, METH_VARARGS,
      "_refracted_activations($self, rule_filter=None, /)\n--\n\n"
      "The refracted activations, as records; pyds.Engine.debug.refracted reads it." },
    { "close", (PyCFunction)PydsEngine_close, METH_NOARGS,
      "close($self, /)\n--\n\n"
      "Release the C engine and every registered callback now; idempotent.\n\n"
      "An engine that is never closed, one in a reference cycle with its\n"
      "callbacks included, is freed by the collector. Raises from inside one\n"
      "of the engine's own callbacks, and changes nothing. After close() the\n"
      "engine raises on use." },
    { "__enter__", (PyCFunction)PydsEngine_enter, METH_NOARGS,
      pyds_engine_enter_doc },
    { "__exit__", (PyCFunction)PydsEngine_exit, METH_VARARGS,
      pyds_engine_exit_doc },
    { NULL, NULL, 0, NULL },
};

PyDoc_STRVAR(pyds_engine_closed_doc,
"True once close() has released the engine.");

/* One of the engine's ids, as libds holds it: None for one not given or
   given as "". */
static PyObject *
PydsEngine_id(PydsEngineObject *self,
              ds_result_t (*get)(const ds_engine_t *, const char **))
{
    if (self->engine == NULL) {
        PyErr_SetString(PyExc_ValueError, "operation on a closed Engine");
        return NULL;
    }
    const char *id = NULL;
    ds_result_t r = get(self->engine, &id);
    if (r.status != DS_OK) {
        return pyds_raise_from_result(r);
    }
    if (id == NULL) {
        Py_RETURN_NONE;
    }
    return PyUnicode_FromString(id);
}

static PyObject *
PydsEngine_get_run_id(PydsEngineObject *self, void *Py_UNUSED(closure))
{
    return PydsEngine_id(self, ds_engine_get_run_id);
}

static PyObject *
PydsEngine_get_tier_id(PydsEngineObject *self, void *Py_UNUSED(closure))
{
    return PydsEngine_id(self, ds_engine_get_tier_id);
}

PyDoc_STRVAR(pyds_engine_run_id_doc,
"The run id the engine was given, or None for none.");
PyDoc_STRVAR(pyds_engine_tier_id_doc,
"The tier id the engine was given, or None for none.");

static PyGetSetDef PydsEngine_getset[] = {
    { "closed", (getter)PydsEngine_get_closed, NULL,
      pyds_engine_closed_doc, NULL },
    { "run_id", (getter)PydsEngine_get_run_id, NULL,
      pyds_engine_run_id_doc, NULL },
    { "tier_id", (getter)PydsEngine_get_tier_id, NULL,
      pyds_engine_tier_id_doc, NULL },
    { NULL, NULL, NULL, NULL, NULL },
};

/* The extension's half of pyds.Engine, which subclasses it in Python
   (pyds/engine.py): the handle, the marshalling and the trampolines are
   here, the public shape is there. Nothing outside pyds names this type.

   A HEAP TYPE, made from this spec: the extension builds against the 3.12
   limited API (abi3, PY.16), where a static PyTypeObject cannot be defined. */
static PyType_Slot pyds_engine_slots[] = {
    /* Opens with its text signature (PY.13), which is what inspect.signature
       and mypy.stubtest read for the constructor. */
    { Py_tp_doc, (void *)("_Engine(*, run_id=None, tier_id=None)\n--\n\n"
                          "The extension's half of pyds.Engine; use pyds.Engine.") },
    { Py_tp_new,      (void *)PyType_GenericNew },
    { Py_tp_init,     (void *)PydsEngine_init },
    { Py_tp_dealloc,  (void *)PydsEngine_dealloc },
    { Py_tp_finalize, (void *)PydsEngine_finalize },
    { Py_tp_traverse, (void *)PydsEngine_traverse },
    { Py_tp_clear,    (void *)PydsEngine_clear },
    { Py_tp_methods,  (void *)PydsEngine_methods },
    { Py_tp_getset,   (void *)PydsEngine_getset },
    { 0, NULL },
};

static PyType_Spec pyds_engine_spec = {
    .name      = "pyds._pyds._Engine",
    .basicsize = sizeof(PydsEngineObject),
    .itemsize  = 0,
    /* IMMUTABLETYPE: a heap type takes attribute assignment unless told not
       to, and the static type this was did not. */
    .flags     = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE | Py_TPFLAGS_HAVE_GC
               | Py_TPFLAGS_IMMUTABLETYPE,
    .slots     = pyds_engine_slots,
};

PyTypeObject *PydsEngineType;

/* Called by the module's exec slot, which may run more than once in an
   interpreter (pyds_module.c).

   EACH TYPE IS MADE ONCE AND KEPT, in a C global that holds its one strong
   reference, and a second exec adds the same type again. pyds.Engine
   subclasses _Engine and assert_external recognises an EncodedFact by its
   type, so a second exec must not replace either. They are not in module
   state, as PY.16 would otherwise have them: reaching module state from a
   type takes PyType_GetModuleByDef, which joins the limited API at 3.13. The
   module refuses a second interpreter (Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED),
   so one copy of each serves every exec. */
int
pyds_init_engine_type(PyObject *module)
{
    if (PydsEngineType == NULL) {
        PydsEngineType = (PyTypeObject *)PyType_FromSpec(&pyds_engine_spec);
        if (PydsEngineType == NULL) {
            return -1;
        }
    }
    if (PyModule_AddType(module, PydsEngineType) < 0) {
        return -1;
    }
    /* Made once and kept, as above. */
    if (PydsEncodedFactType == NULL) {
        PydsEncodedFactType =
            PyStructSequence_NewType(&pyds_encoded_fact_desc);
        if (PydsEncodedFactType == NULL) {
            return -1;
        }
    }
    if (PyModule_AddObjectRef(module, "EncodedFact",
                              (PyObject *)PydsEncodedFactType) < 0) {
        return -1;
    }
    /* A subclass of str, made once and kept. */
    if (PydsJsonTextType == NULL) {
        PydsJsonTextType = PyType_FromSpecWithBases(&pyds_json_text_spec,
                                                    (PyObject *)&PyUnicode_Type);
        if (PydsJsonTextType == NULL) {
            return -1;
        }
    }
    if (PyModule_AddType(module, (PyTypeObject *)PydsJsonTextType) < 0) {
        return -1;
    }
    return 0;
}

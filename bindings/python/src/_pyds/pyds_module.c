/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * pyds — Python binding for libds.
 *
 * The engine type and the atom readers. The exceptions are Python, in
 * pyds/errors.py, raised through errors.c.
 */

#include "pyds.h"
#include "ds_names.h"

/* The capabilities this build of libds has code for ([NLFC.10.1]), as plain
   numbers: pyds/__init__.py makes them `Capability` members, so the enum is
   written once, in Python, from the proto. */
static PyObject *
pyds_build_capabilities(PyObject *Py_UNUSED(module),
                        PyObject *Py_UNUSED(ignored))
{
    /* Sized, then filled. The list is fixed when libds is built, so the
       second call writes exactly the count the first returned. */
    size_t n = ds_build_capabilities(NULL, 0);
    ds_capability_t *caps = PyMem_New(ds_capability_t, n);
    if (caps == NULL) {
        return PyErr_NoMemory();
    }
    ds_build_capabilities(caps, n);

    PyObject *out = PyTuple_New((Py_ssize_t)n);
    if (out == NULL) {
        PyMem_Free(caps);
        return NULL;
    }
    for (size_t i = 0; i < n; ++i) {
        PyObject *num = PyLong_FromLong((long)caps[i]);
        if (num == NULL) {
            Py_DECREF(out);
            PyMem_Free(caps);
            return NULL;
        }
        PyTuple_SetItem(out, (Py_ssize_t)i, num);  /* steals num */
    }
    PyMem_Free(caps);
    return out;
}

PyDoc_STRVAR(pyds_build_capabilities_doc,
"build_capabilities($module, /)\n"
"--\n"
"\n"
"Return the capabilities this build of libds has code for.\n"
"\n"
"A tuple of their registry numbers, ascending. ``pyds.BUILD_CAPABILITIES``\n"
"is the public form.");

/* One ds_names.h vocabulary, as the tuple of its members' names in value
   order: every value below DS_NAMES_PROBE that the function names, the
   fallback it gives a non-member left out. */
#define DS_NAMES_PROBE 64

static PyObject *
names_vocabulary(const char *(*name_of)(int), const char *fallback)
{
    PyObject *out = PyList_New(0);
    if (out == NULL) {
        return NULL;
    }
    for (int v = 0; v < DS_NAMES_PROBE; ++v) {
        const char *name = name_of(v);
        if (strcmp(name, fallback) == 0) {
            continue;
        }
        PyObject *s = PyUnicode_FromString(name);
        if (s == NULL || PyList_Append(out, s) < 0) {
            Py_XDECREF(s);
            Py_DECREF(out);
            return NULL;
        }
        Py_DECREF(s);
    }
    PyObject *t = PyList_AsTuple(out);
    Py_DECREF(out);
    return t;
}

/* ds_names.h's functions take each vocabulary's own enum type; these take
   an int, so one prober serves all four. */
static const char *
names_event_kind(int v)
{
    return ds_names_event_kind((ds_stream_ev_kind_t)v);
}

static const char *
names_log_level(int v)
{
    return ds_names_log_level((ds_log_level_t)v);
}

static const char *
names_metric_kind(int v)
{
    return ds_names_metric_kind((ds_metric_kind_t)v);
}

static const char *
names_cache_removal(int v)
{
    return ds_names_cache_removal((ds_cache_removal_reason_t)v);
}

static PyObject *
pyds_names(PyObject *Py_UNUSED(module), PyObject *Py_UNUSED(ignored))
{
    static const struct {
        const char *key;
        const char *(*name_of)(int);
        const char *fallback;
    } vocabs[] = {
        {"event_kind",    names_event_kind,    "unknown"},
        {"log_level",     names_log_level,     "UNKNOWN"},
        {"metric_kind",   names_metric_kind,   "unknown"},
        {"cache_removal", names_cache_removal, "unknown"},
    };
    PyObject *d = PyDict_New();
    if (d == NULL) {
        return NULL;
    }
    for (size_t i = 0; i < sizeof vocabs / sizeof vocabs[0]; ++i) {
        PyObject *t = names_vocabulary(vocabs[i].name_of,
                                       vocabs[i].fallback);
        if (t == NULL || PyDict_SetItemString(d, vocabs[i].key, t) < 0) {
            Py_XDECREF(t);
            Py_DECREF(d);
            return NULL;
        }
        Py_DECREF(t);
    }
    return d;
}

PyDoc_STRVAR(pyds_names_doc,
"_names($module, /)\n"
"--\n"
"\n"
"Return ds_names.h's vocabularies as this extension renders them.\n"
"\n"
"A dict from vocabulary to the tuple of its names in value order. The pyds\n"
"suite holds each of pyds.enums's StrEnums to it.");

static PyMethodDef pyds_module_methods[] = {
    {"build_capabilities", pyds_build_capabilities, METH_NOARGS,
     pyds_build_capabilities_doc},
    {"_names", pyds_names, METH_NOARGS, pyds_names_doc},
    {NULL, NULL, 0, NULL},
};

/* The module's Py_mod_exec slot: fill a module the import system made. It may
   run more than once in one interpreter (a second module from the same spec,
   or a reload), so everything it does is safe to repeat. */
static int
pyds_module_exec(PyObject *m)
{
    if (pyds_init_engine_type(m) < 0) {
        return -1;
    }
    if (pyds_init_atoms(m) < 0) {
        return -1;
    }
    /* libds.h's ds_admission_t, the one definition of its numbers:
       pyds.Admission takes its members' values from these. */
    if (PyModule_AddIntConstant(m, "_ADMIT_EITHER", DS_ADMIT_EITHER) < 0
        || PyModule_AddIntConstant(m, "_ADMIT_TRUE_ONLY",
                                   DS_ADMIT_TRUE_ONLY) < 0
        || PyModule_AddIntConstant(m, "_ADMIT_FALSE_ONLY",
                                   DS_ADMIT_FALSE_ONLY) < 0) {
        return -1;
    }
    return 0;
}

static PyModuleDef_Slot pyds_module_slots[] = {
    {Py_mod_exec, pyds_module_exec},
    /* The engine, JsonText and EncodedFact types are made once and kept in C
       globals (engine.c, pyds_init_engine_type), and the FactId type and
       pyds.errors._error_for are cached in C globals, so two interpreters
       would share them. A subinterpreter is refused the module rather than
       given that. */
    {Py_mod_multiple_interpreters, Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED},
    /* No engine has a per-object critical section, so a free-threaded
       interpreter must keep its GIL while pyds is loaded (PEP 703). The slot
       is 3.13's, and the 3.12 limited API this builds against (abi3, PY.16)
       does not define it, so this compiles only in a build outside it. Without
       it a module is taken to need the GIL, which is what it would declare,
       and a free-threaded interpreter cannot load an abi3 extension anyway.
       Keyed on the slot, not PY_VERSION_HEX: that is the headers' version,
       which says nothing about what the limited API admits. */
#ifdef Py_mod_gil
    {Py_mod_gil, Py_MOD_GIL_USED},
#endif
    {0, NULL},
};

/* Multi-phase initialisation (PEP 489). m_size is 0: the module keeps no
   state of its own yet. */
static struct PyModuleDef pyds_module_def = {
    .m_base    = PyModuleDef_HEAD_INIT,
    .m_name    = "_pyds",
    .m_doc     = "The libds extension behind pyds.",
    .m_size    = 0,
    .m_methods = pyds_module_methods,
    .m_slots   = pyds_module_slots,
};

PyMODINIT_FUNC
PyInit__pyds(void)
{
    return PyModuleDef_Init(&pyds_module_def);
}

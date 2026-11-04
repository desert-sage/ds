/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * schema.c — a ds_schema_t read into plain Python values.
 *
 * pyds.Schema and pyds.Slot are frozen dataclasses (pyds/engine.py); this
 * reads one schema out of libds into the tuple they are built from, so the
 * result holds nothing of the engine's. Names are the DS language's own
 * spelling ("logical", "Int", "key"), which pyds.enums gives as members.
 */

#include "pyds.h"

/* NULL for a value this pyds does not know, which the caller raises on: a
   placeholder name is indistinguishable from corrupt data. No
   `default:`, so -Wswitch names the case a new libds member needs. */
static const char *
slot_type_name(ds_slot_type_t t)
{
    switch (t) {
    case DS_SLOT_TYPE_INT:      return "Int";
    case DS_SLOT_TYPE_FLOAT:    return "Float";
    case DS_SLOT_TYPE_STRING:   return "String";
    case DS_SLOT_TYPE_BOOL:     return "Bool";
    case DS_SLOT_TYPE_JSON:     return "Json";
    case DS_SLOT_TYPE_SCHEMA:   return "Schema";
    case DS_SLOT_TYPE_BYTES:    return "Bytes";
    case DS_SLOT_TYPE_TIME:     return "Time";
    case DS_SLOT_TYPE_DATE:     return "Date";
    case DS_SLOT_TYPE_DURATION: return "Duration";
    }
    return NULL;
}

static const char *
lifecycle_name(ds_schema_lifecycle_t lc)
{
    switch (lc) {
    case DS_SCHEMA_LIFECYCLE_LOGICAL:  return "logical";
    case DS_SCHEMA_LIFECYCLE_TTL:      return "ttl";
    /* The built-in fault schemas, ComputationError and TypeError
       ([NDBG.2.2], [LSCP.2.6.2]). An integrator tells them from its own
       schemas by this, never by name. */
    case DS_SCHEMA_LIFECYCLE_INTERNAL: return "internal";
    }
    return NULL;
}

/* None for a slot that has no role: every slot of a schema that is not
   `logical` ([LFAC.1.7]). */
static PyObject *
identity_role_name(ds_identity_role_t role)
{
    switch (role) {
    case DS_IDENTITY_UNSPECIFIED: Py_RETURN_NONE;
    case DS_IDENTITY_KEY:         return PyUnicode_FromString("key");
    case DS_IDENTITY_MUTABLE:     return PyUnicode_FromString("mutable");
    case DS_IDENTITY_ENGINE:      return PyUnicode_FromString("engine");
    }
    PyErr_Format(PyExc_RuntimeError,
                 "libds reports identity role %d, which this pyds does not "
                 "know", (int)role);
    return NULL;
}

static PyObject *
known_name(const char *name, const char *what, int value)
{
    if (name == NULL) {
        PyErr_Format(PyExc_RuntimeError,
                     "libds reports %s %d, which this pyds does not know",
                     what, value);
        return NULL;
    }
    return PyUnicode_FromString(name);
}

static PyObject *
optional_string(const char *s)
{
    if (s == NULL) {
        Py_RETURN_NONE;
    }
    return PyUnicode_FromString(s);
}

/* (name, type, schema_ref, nullable, identity, sampled, retained,
   hydration_eligible, tolerance, docstring) */
static PyObject *
slot_record(const ds_slot_desc_t *desc)
{
    PyObject *ref = NULL;
    if (desc->schema_ref != NULL) {
        const char *ref_name = NULL;
        ds_result_t r = ds_schema_get_name(desc->schema_ref, &ref_name);
        if (r.status != DS_OK) {
            return pyds_raise_from_result(r);
        }
        ref = PyUnicode_FromString(ref_name ? ref_name : "");
    }
    else {
        ref = Py_NewRef(Py_None);
    }
    PyObject *name = PyUnicode_FromString(desc->name ? desc->name : "");
    PyObject *type = known_name(slot_type_name(desc->type), "slot type",
                                 (int)desc->type);
    PyObject *identity = identity_role_name(desc->identity_role);
    PyObject *tolerance = desc->has_tolerance
        ? PyFloat_FromDouble(desc->tolerance) : Py_NewRef(Py_None);
    PyObject *doc = optional_string(desc->docstring);
    PyObject *out = NULL;
    if (ref != NULL && name != NULL && type != NULL && identity != NULL
        && tolerance != NULL && doc != NULL) {
        out = Py_BuildValue("(OOOOOOOOOO)", name, type, ref,
                            desc->nullable ? Py_True : Py_False, identity,
                            desc->sampled ? Py_True : Py_False,
                            desc->retained ? Py_True : Py_False,
                            desc->hydration_eligible ? Py_True : Py_False,
                            tolerance, doc);
    }
    Py_XDECREF(ref);
    Py_XDECREF(name);
    Py_XDECREF(type);
    Py_XDECREF(identity);
    Py_XDECREF(tolerance);
    Py_XDECREF(doc);
    return out;
}

/* (name, lifecycle, ttl_ns, slots, source, proto_source), with source
   (file, line, column) or None and slots a tuple of slot_record's. */
PyObject *
pyds_schema_record(const ds_schema_t *schema)
{
    PyObject *name = NULL, *lifecycle = NULL, *ttl = NULL, *slots = NULL;
    PyObject *source = NULL, *proto = NULL, *out = NULL;
    ds_result_t r;

    const char *name_c = NULL;
    r = ds_schema_get_name(schema, &name_c);
    if (r.status != DS_OK) {
        goto status;
    }
    name = PyUnicode_FromString(name_c ? name_c : "");
    if (name == NULL) {
        goto done;
    }

    ds_schema_lifecycle_t lc;
    r = ds_schema_get_lifecycle(schema, &lc);
    if (r.status != DS_OK) {
        goto status;
    }
    lifecycle = known_name(lifecycle_name(lc), "schema lifecycle", (int)lc);
    if (lifecycle == NULL) {
        goto done;
    }

    uint64_t ttl_ns = 0;
    r = ds_schema_get_ttl_ns(schema, &ttl_ns);
    if (r.status != DS_OK) {
        goto status;
    }
    ttl = PyLong_FromUnsignedLongLong((unsigned long long)ttl_ns);
    if (ttl == NULL) {
        goto done;
    }

    uint32_t n = 0;
    r = ds_schema_get_slot_count(schema, &n);
    if (r.status != DS_OK) {
        goto status;
    }
    slots = PyTuple_New((Py_ssize_t)n);
    if (slots == NULL) {
        goto done;
    }
    for (uint32_t i = 0; i < n; ++i) {
        ds_slot_desc_t desc;
        r = ds_schema_get_slot(schema, i, &desc);
        if (r.status != DS_OK) {
            goto status;
        }
        PyObject *slot = slot_record(&desc);
        if (slot == NULL) {
            goto done;
        }
        PyTuple_SetItem(slots, (Py_ssize_t)i, slot);  /* steals slot */
    }

    /* Present only for a schema the artefact declared: one the engine
       declares itself has no source position. */
    const char *file = NULL;
    uint32_t line = 0, col = 0;
    r = ds_schema_get_source(schema, &file, &line, &col);
    if (r.status != DS_OK) {
        goto status;
    }
    source = file == NULL
        ? Py_NewRef(Py_None)
        : Py_BuildValue("(sII)", file, (unsigned int)line, (unsigned int)col);
    if (source == NULL) {
        goto done;
    }

    const char *text = NULL;
    size_t len = 0;
    r = ds_schema_get_proto_source(schema, &text, &len);
    if (r.status != DS_OK) {
        goto status;
    }
    proto = text == NULL
        ? Py_NewRef(Py_None)
        : PyUnicode_FromStringAndSize(text, (Py_ssize_t)len);
    if (proto == NULL) {
        goto done;
    }

    out = PyTuple_Pack(6, name, lifecycle, ttl, slots, source, proto);
    goto done;

status:
    (void)pyds_raise_from_result(r);
done:
    Py_XDECREF(name);
    Py_XDECREF(lifecycle);
    Py_XDECREF(ttl);
    Py_XDECREF(slots);
    Py_XDECREF(source);
    Py_XDECREF(proto);
    return out;
}

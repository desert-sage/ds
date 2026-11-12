/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * pyds atoms — libds's own readers, for Python.
 *
 * NO CODEC HERE. Every function below hands bytes to libds and returns what
 * libds answered: the framing is `ds_pbf_next_atom`, a body's wire fields are
 * `ds_pbf_next_field`, a body's typed fields are `ds_rfcs_visit_atom`.
 *
 *   _pyds.next_atom(buf, pos, partial) -> (field, body, end) | None
 *       One atom of a container, named by its field number ([RFCS.16.1]), for
 *       pyds.atoms.iter_atoms. A number this build has no entry for is
 *       returned like any other, and the caller applies its band.
 *   _pyds.wire_fields(body) -> [(field, wire, value), ...]
 *       A body's top-level fields. `value` is an int for wire types 0, 1 and
 *       5 (the varint as read, the fixed64 / fixed32 little-endian) and bytes
 *       for wire type 2.
 *   _pyds.visit_atom(field, body)
 *       -> [(kind, name, number, index, depth, message, value), ...]
 *       The generic reader's walk, one tuple per visited field.
 *   _pyds.atom_message_name(field) -> str | None
 *       The atom's proto message, None for a number with no entry.
 *
 * A field number is an int, or anything with __index__, in 0..2**32-1; out
 * of range it is an OverflowError, never wrapped.
 *
 * A malformed input raises pyds.InputError with Status.PARSE, naming the
 * offset libds stopped at.
 */
#include "pyds.h"

#include <stdio.h>

#include "rfcs/rfcs.h"
#include "dsc/pbf_reader.h"

/* An atom's field number from Python: an int, or anything with __index__,
   range-checked rather than parsed with a wrapping format unit (`I`, `k`). */
static int
field_arg(PyObject *arg, uint32_t *out)
{
    PyObject *n = PyNumber_Index(arg);
    if (n == NULL) {
        return -1;
    }
    unsigned long long v = PyLong_AsUnsignedLongLong(n);
    Py_DECREF(n);
    if (v == (unsigned long long)-1 && PyErr_Occurred()) {
        return -1;              /* negative: OverflowError, already set */
    }
    if (v > UINT32_MAX) {
        PyErr_SetString(PyExc_OverflowError,
                        "atom field number out of range for uint32");
        return -1;
    }
    *out = (uint32_t)v;
    return 0;
}

/* A malformed input, as the pyds.errors exception for `status`, with the
   offset libds stopped at in its detail. */
static PyObject *raise_at(int status, const char *what, size_t offset)
{
    char detail[128];
    snprintf(detail, sizeof detail, "%s at byte %zu", what, offset);
    return pyds_raise_status(status, detail);
}

static PyObject *pyds_wire_fields(PyObject *self, PyObject *arg)
{
    Py_buffer view;
    (void)self;
    if (PyObject_GetBuffer(arg, &view, PyBUF_SIMPLE) < 0)
        return NULL;
    const uint8_t *msg = (const uint8_t *)view.buf;
    size_t len = (size_t)view.len, pos = 0;

    PyObject *list = PyList_New(0);
    if (list == NULL) { PyBuffer_Release(&view); return NULL; }
    while (pos < len) {
        ds_pbf_field_t f;
        ds_pbf_step_t st = ds_pbf_next_field(msg, len, pos, &f);
        if (st != DS_PBF_OK) {
            raise_at(DS_ERR_PARSE, st == DS_PBF_EOF
                         ? "truncated field" : "malformed field", pos);
            goto fail;
        }
        PyObject *item = f.wire == 2u
            ? Py_BuildValue("(IIy#)", (unsigned int)f.field, (unsigned int)f.wire,
                            (const char *)f.val, (Py_ssize_t)f.val_len)
            : Py_BuildValue("(IIK)", (unsigned int)f.field, (unsigned int)f.wire,
                            (unsigned long long)f.u64);
        if (item == NULL || PyList_Append(list, item) < 0) {
            Py_XDECREF(item);
            goto fail;
        }
        Py_DECREF(item);
        pos = f.next;
    }
    PyBuffer_Release(&view);
    return list;

fail:
    PyBuffer_Release(&view);
    Py_DECREF(list);
    return NULL;
}

/* NULL for a kind this pyds does not know, which collect() raises on rather
   than indexing past a table. No `default:`, so -Wswitch names the
   case a new libds kind needs. */
static const char *kind_name(ds_rfcs_field_kind_t kind)
{
    switch (kind) {
    case DS_RFCS_FIELD_INT:    return "int";
    case DS_RFCS_FIELD_UINT:   return "uint";
    case DS_RFCS_FIELD_DOUBLE: return "double";
    case DS_RFCS_FIELD_BOOL:   return "bool";
    case DS_RFCS_FIELD_ENUM:   return "enum";
    case DS_RFCS_FIELD_STRING: return "string";
    case DS_RFCS_FIELD_BYTES:  return "bytes";
    case DS_RFCS_FIELD_ENTER:  return "enter";
    case DS_RFCS_FIELD_LEAVE:  return "leave";
    }
    return NULL;
}

typedef struct { PyObject *list; int failed; } visit_ctx_t;

static bool collect(void *ctx, const ds_rfcs_field_t *f)
{
    visit_ctx_t *c = ctx;
    const char *kname = kind_name(f->kind);
    if (kname == NULL) {
        PyErr_Format(PyExc_RuntimeError,
                     "libds reports field kind %d, which this pyds does not know",
                     (int)f->kind);
        c->failed = 1;
        return false;
    }
    PyObject *value;
    switch (f->kind) {
    case DS_RFCS_FIELD_INT:    value = PyLong_FromLongLong((long long)f->v.i); break;
    case DS_RFCS_FIELD_UINT:   value = PyLong_FromUnsignedLongLong(
                                   (unsigned long long)f->v.u); break;
    case DS_RFCS_FIELD_DOUBLE: value = PyFloat_FromDouble(f->v.d); break;
    case DS_RFCS_FIELD_BOOL:   value = PyBool_FromLong(f->v.b); break;
    case DS_RFCS_FIELD_ENUM:
        value = Py_BuildValue("(iz)", (int)f->v.e.number, f->v.e.name);
        break;
    case DS_RFCS_FIELD_STRING:
        value = PyUnicode_DecodeUTF8((const char *)f->v.s.p,
                                     (Py_ssize_t)f->v.s.len, "strict");
        break;
    case DS_RFCS_FIELD_BYTES:
        value = PyBytes_FromStringAndSize((const char *)f->v.s.p,
                                          (Py_ssize_t)f->v.s.len);
        break;
    default:
        value = Py_None;
        Py_INCREF(value);
    }
    if (value == NULL) { c->failed = 1; return false; }
    PyObject *item = Py_BuildValue(
        "(szIiIzN)", kname, f->name, (unsigned int)f->number,
        (int)f->index, (unsigned int)f->depth, f->message, value);
    if (item == NULL || PyList_Append(c->list, item) < 0) {
        Py_XDECREF(item);
        c->failed = 1;
        return false;
    }
    Py_DECREF(item);
    return true;
}

static PyObject *pyds_visit_atom(PyObject *self, PyObject *args)
{
    PyObject *field_obj;
    Py_buffer view;
    uint32_t field;
    (void)self;
    if (!PyArg_ParseTuple(args, "Oy*", &field_obj, &view))
        return NULL;
    if (field_arg(field_obj, &field) < 0) { PyBuffer_Release(&view); return NULL; }

    visit_ctx_t c = { PyList_New(0), 0 };
    if (c.list == NULL) { PyBuffer_Release(&view); return NULL; }
    ds_result_t r = ds_rfcs_visit_atom(field, (const uint8_t *)view.buf,
                                       (size_t)view.len, collect, &c);
    PyBuffer_Release(&view);
    if (c.failed) { Py_DECREF(c.list); return NULL; }
    if (r.status != DS_OK) { Py_DECREF(c.list); return pyds_raise_from_result(r); }
    return c.list;
}

static PyObject *pyds_atom_message_name(PyObject *self, PyObject *arg)
{
    uint32_t field;
    (void)self;
    if (field_arg(arg, &field) < 0)
        return NULL;
    const char *n = ds_rfcs_message_name(field);
    if (n == NULL)
        Py_RETURN_NONE;
    return PyUnicode_FromString(n);
}

/* One step of pyds.atoms.iter_atoms: the atom whose frame starts at `pos`, as
   (field, body, end), by `ds_pbf_next_atom` -- the framing every libds reader
   stands on, and not `ds_rfcs_next`, which also judges a number this build has
   no entry for by its band: a stream policy, which a caller applies itself
   ([RFCS.16.3]). A partial atom there is None
   when `partial` ([RFCS.19.2]) and an error otherwise; bytes no append could
   repair are an error either way. One step per call, so the walk is lazy. */
static PyObject *pyds_next_atom(PyObject *self, PyObject *args)
{
    Py_buffer view;
    Py_ssize_t pos;
    int partial = 0;
    (void)self;
    if (!PyArg_ParseTuple(args, "y*np", &view, &pos, &partial))
        return NULL;
    if (pos < 0 || pos > view.len) {
        PyBuffer_Release(&view);
        PyErr_SetString(PyExc_ValueError, "atom position outside the buffer");
        return NULL;
    }
    ds_pbf_atom_t a;
    ds_pbf_step_t st = ds_pbf_next_atom((const uint8_t *)view.buf, (size_t)view.len,
                                        (size_t)pos, &a);
    PyObject *out;
    if (st == DS_PBF_OK) {
        out = Py_BuildValue("(Iy#n)", (unsigned int)a.field, (const char *)a.body,
                            (Py_ssize_t)a.body_len, (Py_ssize_t)a.next);
    } else if (st == DS_PBF_EOF && partial) {
        out = Py_NewRef(Py_None);
    } else {
        out = raise_at(DS_ERR_PARSE, st == DS_PBF_EOF
                           ? "truncated atom" : "malformed atom frame", (size_t)pos);
    }
    PyBuffer_Release(&view);
    return out;
}

/* pyds.atoms.frame: one framed atom, `ds_rfcs_pack_atom` ([RFCS.19.1]). A
   number with no registry entry is refused here, before libds is asked (PY.6),
   since libds refuses one too and the Python error says which. */
static PyObject *pyds_frame(PyObject *self, PyObject *args)
{
    PyObject *field_obj;
    Py_buffer view;
    uint32_t field;
    (void)self;
    if (!PyArg_ParseTuple(args, "Oy*", &field_obj, &view))
        return NULL;
    if (field_arg(field_obj, &field) < 0) {
        PyBuffer_Release(&view);
        return NULL;
    }
    if (ds_pbf_lookup(field) == NULL) {
        PyBuffer_Release(&view);
        PyErr_Format(PyExc_ValueError, "field %u is not an allocated atom",
                     (unsigned int)field);
        return NULL;
    }
    size_t need = ds_rfcs_atom_framed_size(field, (size_t)view.len);
    PyObject *out = PyBytes_FromStringAndSize(NULL, (Py_ssize_t)need);
    if (out == NULL) {
        PyBuffer_Release(&view);
        return NULL;
    }
    size_t got = 0;
    /* PyBytes_AsString, not the macro, which is outside the limited API
       (PY.16); `out` is a fresh bytes object, so it cannot fail. */
    ds_result_t r = ds_rfcs_pack_atom(field, (const uint8_t *)view.buf, (size_t)view.len,
                                      (uint8_t *)PyBytes_AsString(out), need, &got);
    PyBuffer_Release(&view);
    if (r.status != DS_OK) {
        Py_DECREF(out);
        return pyds_raise_from_result(r);
    }
    if (got != need) {
        /* ds_rfcs_atom_framed_size and ds_rfcs_pack_atom disagree: libds's
           contract, broken. */
        Py_DECREF(out);
        PyErr_Format(PyExc_SystemError, "libds framed %zu bytes, having sized %zu",
                     got, need);
        return NULL;
    }
    return out;
}

/* pyds.atoms.container_of: libds's answer as its enum number, which pyds.atoms
   names. */
static PyObject *pyds_container_of(PyObject *self, PyObject *arg)
{
    Py_buffer view;
    (void)self;
    if (PyObject_GetBuffer(arg, &view, PyBUF_SIMPLE) < 0)
        return NULL;
    ds_pbf_container_t c = ds_pbf_container_of((const uint8_t *)view.buf, (size_t)view.len);
    PyBuffer_Release(&view);
    return PyLong_FromLong((long)c);
}

/* Each docstring opens with its text signature (PY.13), which is what
   inspect.signature, help() and mypy.stubtest read. */
static PyMethodDef atoms_methods[] = {
    { "next_atom", pyds_next_atom, METH_VARARGS,
      "next_atom($module, buf, pos, partial, /)\n--\n\n"
      "Return the atom whose frame starts at ``pos`` as (field, body, end).\n\n"
      "None for a partial atom there when ``partial``." },
    { "frame", pyds_frame, METH_VARARGS,
      "frame($module, field, body, /)\n--\n\n"
      "Return one framed atom, as bytes." },
    { "container_of", pyds_container_of, METH_O,
      "container_of($module, buf, /)\n--\n\n"
      "Return libds's ds_pbf_container_t number for a container." },
    { "wire_fields", pyds_wire_fields, METH_O,
      "wire_fields($module, body, /)\n--\n\n"
      "Return a body's top-level fields as a list of (field, wire, value)." },
    { "visit_atom", pyds_visit_atom, METH_VARARGS,
      "visit_atom($module, field, body, /)\n--\n\n"
      "Return libds's typed walk of a body.\n\n"
      "A list of (kind, name, number, index, depth, message, value), one per\n"
      "field visited." },
    { "atom_message_name", pyds_atom_message_name, METH_O,
      "atom_message_name($module, field, /)\n--\n\n"
      "Return the proto message of the atom ``field`` names, or None." },
    { NULL, NULL, 0, NULL }
};

int pyds_init_atoms(PyObject *module)
{
    return PyModule_AddFunctions(module, atoms_methods);
}

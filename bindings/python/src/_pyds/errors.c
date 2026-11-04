/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * errors.c — a failed ds_result_t as a Python exception.
 *
 * The exception classes are Python, in pyds/errors.py, with the [NERR.3.1]
 * range table that picks one. This file only hands the status and
 * detail to `pyds.errors._error_for` and raises what comes back, so every
 * libds failure reaches Python one way and carries its status as an
 * attribute, not as text in the message.
 */

#include <string.h>   /* the limited API's Python.h does not bring it (PY.16) */

#include "pyds.h"

/* pyds.errors._error_for, imported on first use: `pyds/__init__.py` imports
   this extension before `pyds.errors` exists in sys.modules. */
static PyObject *error_for = NULL;

PyObject *
pyds_raise_status(int status, const char *detail)
{
    /* A Python exception already pending -- one a callback raised during the
       call that failed -- becomes the new error's __cause__, so its
       traceback reaches whoever catches the pyds error. */
    PyObject *pending = PyErr_GetRaisedException();

    if (error_for == NULL) {
        PyObject *mod = PyImport_ImportModule("pyds.errors");
        if (mod != NULL) {
            error_for = PyObject_GetAttrString(mod, "_error_for");
            Py_DECREF(mod);
        }
        if (error_for == NULL) {
            Py_XDECREF(pending);
            return NULL;
        }
    }
    const char *text = detail != NULL ? detail : "";
    PyObject *exc = PyObject_CallFunction(
        error_for, "iN", status,
        PyUnicode_DecodeUTF8(text, (Py_ssize_t)strlen(text), "replace"));
    if (exc == NULL) {
        Py_XDECREF(pending);
        return NULL;
    }
    if (pending != NULL) {
        PyException_SetCause(exc, pending);   /* steals pending */
    }
    PyErr_SetRaisedException(exc);            /* steals exc */
    return NULL;
}

PyObject *
pyds_raise_from_result(ds_result_t r)
{
    if (r.status == DS_OK) {
        Py_RETURN_NONE;
    }
    return pyds_raise_status((int)r.status, r.detail);
}

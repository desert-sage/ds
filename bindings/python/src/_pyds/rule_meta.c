/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rule_meta.c — a rule's metadata (ds_rule_meta_view_t) read into plain
 * Python values, the tuple pyds.Rule (pyds/engine.py) is built from.
 */

#include "pyds.h"

/* (name, cooldown_ns, source, debug_name_template), each optional member
   None when the artefact does not carry it, and source (file, line, column). */
PyObject *
pyds_rule_record(const ds_rule_meta_view_t *view)
{
    PyObject *name = PyUnicode_FromString(view->rule_name
                                          ? view->rule_name : "");
    PyObject *cooldown = view->has_cool
        ? PyLong_FromUnsignedLongLong((unsigned long long)view->cool_window_ns)
        : Py_NewRef(Py_None);
    PyObject *source = view->has_srcr
        ? Py_BuildValue("(sII)", view->src_file ? view->src_file : "",
                        (unsigned int)view->src_line,
                        (unsigned int)view->src_col)
        : Py_NewRef(Py_None);
    PyObject *template = (view->has_dnam && view->debug_name_template)
        ? PyUnicode_FromString(view->debug_name_template)
        : Py_NewRef(Py_None);
    PyObject *out = NULL;
    if (name != NULL && cooldown != NULL && source != NULL
        && template != NULL) {
        out = PyTuple_Pack(4, name, cooldown, source, template);
    }
    Py_XDECREF(name);
    Py_XDECREF(cooldown);
    Py_XDECREF(source);
    Py_XDECREF(template);
    return out;
}

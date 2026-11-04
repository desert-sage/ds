/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * pyds.h — internal header shared between pyds C extension TUs.
 *
 * The C surface across pyds_module.c / engine.c / errors.c (and later
 * schema.c / rule_meta.c at W11). Tracks ICOM.12 / ICOM.18.W10.
 */
#ifndef PYDS_INTERNAL_H
#define PYDS_INTERNAL_H

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include "libds.h"

/* ----- Exceptions (errors.c) ------------------------------------- */

/* Raise the pyds.errors exception for a non-OK ds_result_t. Returns
 * NULL so callers can `return pyds_raise_from_result(r);`. */
PyObject *pyds_raise_from_result(ds_result_t r);

/* The same, from a status and a detail that did not come in a ds_result_t. */
PyObject *pyds_raise_status(int status, const char *detail);

/* atoms.c — libds's atom readers as module functions. */
int pyds_init_atoms(PyObject *module);

/* ----- Engine type (engine.c) ------------------------------------ */

/* A heap type, made by pyds_init_engine_type at the first exec and kept. */
extern PyTypeObject *PydsEngineType;

int pyds_init_engine_type(PyObject *module);

/* ----- Schemas and rules (schema.c, rule_meta.c) ----------------- */

/* A schema, read into the tuple pyds.Schema is built from. Borrows the
 * schema; the result holds nothing of the engine's. */
PyObject *pyds_schema_record(const ds_schema_t *schema);

/* A rule's metadata, read into the tuple pyds.Rule is built from. */
PyObject *pyds_rule_record(const ds_rule_meta_view_t *view);

#endif /* PYDS_INTERNAL_H */

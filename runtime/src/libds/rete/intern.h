/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/intern.h — string intern table (IRET.1.4).
 *
 * Two equal strings share one pointer; equality is pointer comparison
 * after intern.  The table holds two entry classes in one pointer space
 * (a value equal to a literal must share the literal's pointer, or alpha
 * tests like `where s.name == "lit"` break):
 *
 *   PINNED  — structural strings (schema/slot/rule names, compile-time
 *             literals, sentinels).  Saturated refcount; engine-lifetime;
 *             never freed until ds_rete_intern_destroy.  Created via
 *             ds_rete_intern / ds_rete_intern_cstr.
 *   COUNTED — fact-slot String/Bytes values.  Reference-counted by the
 *             number of live committed fact slots holding the string;
 *             freed and removed when the last such slot retracts.  Created
 *             via ds_rete_intern_value / ds_rete_intern_value_cstr (born
 *             at refcount 0), then acquire()'d at fact commit and
 *             release()'d at fact retract.
 *
 * A value whose content already exists as a PINNED entry shares that pointer and
 * stays pinned.
 */
#ifndef LIBDS2_INTERNAL_RETE_INTERN_H
#define LIBDS2_INTERNAL_RETE_INTERN_H

#include <stddef.h>
#include <stdint.h>

#include "libds.h"

typedef struct ds_rete_intern ds_rete_intern_t;

ds_result_t ds_rete_intern_init(ds_rete_intern_t **out);
void        ds_rete_intern_destroy(ds_rete_intern_t *intern);

/* As PINNED; `str` need not be NUL-terminated. A counted entry of the same content
   is promoted. */
ds_result_t ds_rete_intern(ds_rete_intern_t *intern,
                            const char       *str,
                            size_t            len,
                            const char      **out);

ds_result_t ds_rete_intern_cstr(ds_rete_intern_t *intern,
                                 const char       *str,
                                 const char      **out);

/* As COUNTED, leaving an existing entry's refcount unchanged: a no-op reassert
   returns the existing fact without acquiring. The caller acquires once the fact
   is committed and releases once it retracts. */
ds_result_t ds_rete_intern_value(ds_rete_intern_t *intern,
                                  const char       *str,
                                  size_t            len,
                                  const char      **out);

ds_result_t ds_rete_intern_value_cstr(ds_rete_intern_t *intern,
                                       const char       *str,
                                       const char      **out);

/* Never inserts and never changes a refcount. *out is NULL when absent. */
ds_result_t ds_rete_intern_find(const ds_rete_intern_t *intern,
                                 const char             *str,
                                 size_t                  len,
                                 const char            **out);

/* Once per String/Bytes slot at fact commit. A no-op on a pinned entry or a pointer
   not found. */
void ds_rete_intern_acquire_ptr(ds_rete_intern_t *intern,
                                 const char       *ptr,
                                 size_t            len);

/* Once per String/Bytes slot at fact retract. A no-op on a pinned entry or a pointer
   not found; a release below 0 trips an assertion. */
void ds_rete_intern_release(ds_rete_intern_t *intern,
                             const char       *ptr,
                             size_t            len);

/* Stays flat under dynamic-value churn: a value mis-routed to pinned would grow it. */
size_t ds_rete_intern_pinned_count(const ds_rete_intern_t *intern);

/* Flat under churn: a steady assert/retract cycle recycles through the freelist. */
size_t ds_rete_intern_counted_mallocs(const ds_rete_intern_t *intern);

/* After this, a PINNED insert of a new string trips an assertion. Idempotent. */
void ds_rete_intern_freeze(ds_rete_intern_t *intern);

/* Pre-grows to at least cap buckets. Call before ds_rete_intern_lock. */
ds_result_t ds_rete_intern_presz(ds_rete_intern_t *intern, size_t cap);

/* After this, an insert that would grow the table is DS_ERR_OOM. */
void ds_rete_intern_lock(ds_rete_intern_t *intern);

size_t ds_rete_intern_resize_count(const ds_rete_intern_t *intern);

/* Any out pointer may be NULL. A NULL table yields 0s. */
void ds_rete_intern_mem(const ds_rete_intern_t *intern,
                        size_t                 *out_count,
                        size_t                 *out_string_bytes,
                        size_t                 *out_index_bytes);

/* Zero is no cap. An insert over either cap is DS_ERR_CONTRACT_BREACH, with the
   table unmodified. */
void ds_rete_intern_set_contract_caps(ds_rete_intern_t *intern,
                                       uint32_t          cap_n,
                                       uint32_t          cap_bytes);

bool ds_rete_intern_is_locked(const ds_rete_intern_t *intern);

#endif /* LIBDS2_INTERNAL_RETE_INTERN_H */

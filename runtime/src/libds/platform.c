/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * platform.c — the platform signature ([LDET.2.3]), resolved from preprocessor
 * macros at libds build time, and the session header.
 */

#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "ds_text.h"
#include "dsc/atom_registry.h"
#include "dsc/pbf_reader.h"

#include "engine.h"
#include "version_series.h"

static const char *
detect_os_family(void)
{
#if defined(__linux__)
    return "linux";
#elif defined(__APPLE__) && defined(__MACH__)
    return "macos";
#elif defined(_WIN32) || defined(_WIN64)
    return "windows";
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \
   || defined(__DragonFly__)
    return "bsd";
#else
    return "unknown";
#endif
}

static const char *
detect_cpu_arch(void)
{
#if defined(__x86_64__) || defined(_M_X64)
    return "x86_64";
#elif defined(__aarch64__) || defined(_M_ARM64)
    return "aarch64";
#elif defined(__arm__) || defined(_M_ARM)
    return "arm";
#elif defined(__i386__) || defined(_M_IX86)
    return "x86";
#else
    return "unknown";
#endif
}

/* Two levels, so the argument expands before it is stringified. */
#define PLATFORM_STR_(x) #x
#define PLATFORM_STR(x)  PLATFORM_STR_(x)

static const char *
detect_libc(void)
{
#if defined(__GLIBC__)
    return "glibc-" PLATFORM_STR(__GLIBC__) "." PLATFORM_STR(__GLIBC_MINOR__);
#elif defined(__APPLE__)
    return "apple";
#elif defined(_WIN32) || defined(_WIN64)
    return "msvcrt";
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    return "bsd-libc";
#else
    /* musl defines no feature-test macro, so it reads as unknown. */
    return "unknown";
#endif
}

/* clang defines __GNUC__ too, so it is tested first. */
static const char *
detect_compiler(void)
{
#if defined(__clang__)
    return "clang-" PLATFORM_STR(__clang_major__) "."
                    PLATFORM_STR(__clang_minor__);
#elif defined(__GNUC__)
    return "gcc-" PLATFORM_STR(__GNUC__) "." PLATFORM_STR(__GNUC_MINOR__);
#elif defined(_MSC_VER)
    return "msvc-" PLATFORM_STR(_MSC_VER);
#else
    return "unknown";
#endif
}

static void
free_backend_id_cache(ds_engine_t *engine)
{
    if (engine->platform_sig_backends == NULL) return;
    for (size_t i = 0; i < engine->platform_sig_n_backends; i++) {
        DS_FREE(engine->platform_sig_backends[i]);
    }
    DS_FREE(engine->platform_sig_backends);
    engine->platform_sig_backends   = NULL;
    engine->platform_sig_n_backends = 0;
}

/* The first field of a `backends` entry ([NDET.2.2]): the backing atom's body
   message, such as `SeriesBackendRingBuffer`. */
static const char *
backing_atom_message(uint32_t atom_field)
{
    const ds_atom_reg_entry_t *e = ds_pbf_lookup(atom_field);
    return (e != NULL && e->message != NULL) ? e->message : "?";
}

static ds_result_t
build_backend_id_cache(ds_engine_t *engine)
{
    free_backend_id_cache(engine);
    if (engine->n_backend_slots == 0) return DS_OK_R;

    char **arr = DS_CALLOC(engine->n_backend_slots, sizeof(*arr));
    if (arr == NULL) {
        return DS_ERR_R(DS_ERR_OOM,
            "platform-signature: backend list alloc failed");
    }

    for (size_t i = 0; i < engine->n_backend_slots; i++) {
        const ds_series_backend_vtable_t *vt =
            engine->backend_slots[i].vtable;
        if (vt == NULL) {
            arr[i] = DS_STRDUP("(empty-slot)");
        } else {
            const char *atom = backing_atom_message(vt->atom_field);
            const char *name = vt->backend_name    ? vt->backend_name    : "";
            const char *ver  = vt->backend_version ? vt->backend_version : "";
            size_t n = strlen(atom) + 1
                     + strlen(name) + 1
                     + strlen(ver)  + 1;
            arr[i] = DS_MALLOC(n);
            if (arr[i] != NULL) {
                ds_text_t t = ds_text(arr[i], n);
                ds_text_str(&t, atom);
                ds_text_char(&t, ':');
                ds_text_str(&t, name);
                ds_text_char(&t, ':');
                ds_text_str(&t, ver);
            }
        }
        if (arr[i] == NULL) {
            for (size_t j = 0; j < i; j++) DS_FREE(arr[j]);
            DS_FREE(arr);
            return DS_ERR_R(DS_ERR_OOM,
                "platform-signature: backend identity strdup failed");
        }
    }
    engine->platform_sig_backends   = arr;
    engine->platform_sig_n_backends = engine->n_backend_slots;
    return DS_OK_R;
}

ds_result_t
ds_engine_get_platform_signature(
    ds_engine_t              *engine,
    ds_platform_signature_t  *out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
            "ds_engine_get_platform_signature: engine must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
            "ds_engine_get_platform_signature: out must not be null");
    }
    DS_ENGINE_REFUSE_IF_REENTERED(engine);

    /* Built once: the `backends` strings are engine-lifetime, and the registered
       set cannot change after ds_engine_new ([NSBK.2.3]). */
    if (engine->platform_sig_backends == NULL) {
        ds_result_t r = build_backend_id_cache(engine);
        if (r.status != DS_OK) return r;
    }

    out->os_family       = detect_os_family();
    out->cpu_arch        = detect_cpu_arch();
    out->libc            = detect_libc();
    out->compiler        = detect_compiler();
    out->libds_version  = ds_libds_version;
    out->backends        = (const char * const *) engine->platform_sig_backends;
    out->n_backends      = engine->platform_sig_n_backends;
    return DS_OK_R;
}

void
ds_engine_platform_signature_dispose(ds_engine_t *engine)
{
    free_backend_id_cache(engine);
}

/* For libds's own callers: the recorder (rfcs/codec.c) runs as the engine's stream
   callback, where the public accessor's guard ([RARC.13.16]) would refuse it. */
void
ds_engine_session_header_fill(const ds_engine_t *engine,
                              ds_session_header_t *out)
{
    /* [LDET.1.10]: the only version a stream carries. */
    out->ds_version = ds_libds_version;
    /* [RFCS.4.3], [RFCS.4.4]: "" for one the integrator did not give. */
    out->session_id = engine->run_id  ? engine->run_id  : "";
    out->tier_id    = engine->tier_id ? engine->tier_id : "";
    /* [RBND.1.3], [RBND.2]. */
    if (engine->dsc_hash_valid) {
        out->dsc_hash               = engine->dsc_hash;
        out->dsc_hash_len           = sizeof(engine->dsc_hash);
        out->capabilities           = engine->dsc_capabilities;
        out->n_capabilities         = engine->n_dsc_capabilities;
        out->dialect_def_sha256     = engine->dsc_def_sha256;
        out->dialect_def_sha256_len = sizeof(engine->dsc_def_sha256);
    } else {
        out->dsc_hash               = NULL;
        out->dsc_hash_len           = 0;
        out->capabilities           = NULL;
        out->n_capabilities         = 0;
        out->dialect_def_sha256     = NULL;
        out->dialect_def_sha256_len = 0;
    }
}

ds_result_t
ds_engine_get_session_header(ds_engine_t         *engine,
                             ds_session_header_t *out)
{
    if (engine == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
            "ds_engine_get_session_header: engine must not be null");
    }
    if (out == NULL) {
        return DS_ERR_R(DS_ERR_INVAL,
            "ds_engine_get_session_header: out must not be null");
    }
    DS_ENGINE_REFUSE_IF_REENTERED(engine);
    ds_engine_session_header_fill(engine, out);
    return DS_OK_R;
}

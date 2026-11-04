/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * alloc_probe.c — the magic-header counting allocator (see alloc_probe.h).
 *
 * Uses libc malloc/realloc/free for the backing store; the probe itself is
 * the integrator's allocator under test. Test-grade (single-threaded, no
 * overflow hardening on count*size — libds validates sizes upstream).
 *
 * Spec: IALC.10.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "alloc_probe.h"

#define PROBE_MAGIC ((uint64_t) 0xA110C0DEA110C0DEULL)

/* 16 bytes => the user payload stays max_align_t-aligned (IALC.7.1). */
typedef struct {
    uint64_t magic;
    uint64_t size;
} probe_hdr_t;

static size_t g_outstanding;
static size_t g_n_alloc;
static size_t g_n_badfree;
static size_t g_n_requests;
static size_t g_fail_at;     /* the request number that fails; 0: none */
static int    g_failed;

/* The next request's site, set by probe_site and taken by that request; the
   failed request's, kept; and how many requests had one. */
static const char *g_site_file, *g_site_func;
static const char *g_failed_file, *g_failed_func;
static size_t      g_n_sited;

void probe_site(const char *file, const char *func)
{
    g_site_file = file;
    g_site_func = func;
}

void probe_failed_site(const char **file, const char **func)
{
    *file = g_failed_file;
    *func = g_failed_func;
}

size_t probe_n_sited(void) { return g_n_sited; }

/* Counts one request, takes its site, and says whether it is the one armed
   to fail. */
static int probe_refuse(void)
{
    const char *file = g_site_file, *func = g_site_func;
    g_site_file = g_site_func = NULL;
    g_n_requests++;
    if (file != NULL) g_n_sited++;
    if (g_fail_at != 0 && g_n_requests == g_fail_at) {
        g_failed      = 1;
        g_failed_file = file;
        g_failed_func = func;
        return 1;
    }
    return 0;
}

static void *probe_new(size_t n)
{
    if (probe_refuse()) return NULL;
    probe_hdr_t *h = malloc(sizeof(probe_hdr_t) + n);
    if (h == NULL) return NULL;
    h->magic = PROBE_MAGIC;
    h->size  = n;
    g_outstanding += n;
    g_n_alloc++;
    return (void *) (h + 1);
}

void *probe_malloc(size_t n) { return probe_new(n); }

void *probe_calloc(size_t count, size_t size)
{
    size_t n = count * size;
    void  *p = probe_new(n);
    if (p != NULL) memset(p, 0, n);
    return p;
}

void probe_free(void *p)
{
    if (p == NULL) return;
    probe_hdr_t *h = (probe_hdr_t *) p - 1;
    if (h->magic != PROBE_MAGIC) { g_n_badfree++; return; }
    g_outstanding -= h->size;
    h->magic = 0;
    free(h);
}

void *probe_realloc(void *p, size_t n)
{
    if (p == NULL) return probe_new(n);
    probe_hdr_t *h = (probe_hdr_t *) p - 1;
    if (h->magic != PROBE_MAGIC) {
        g_n_badfree++;
        g_site_file = g_site_func = NULL;     /* no request: drop its site */
        return NULL;
    }
    if (probe_refuse()) return NULL;          /* the old block stays as it was */
    g_outstanding -= h->size;
    probe_hdr_t *nh = realloc(h, sizeof(probe_hdr_t) + n);
    if (nh == NULL) { g_outstanding += h->size; return NULL; }
    nh->magic = PROBE_MAGIC;
    nh->size  = n;
    g_outstanding += n;
    return (void *) (nh + 1);
}

char *probe_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char  *p = probe_new(n);
    if (p != NULL) memcpy(p, s, n);
    return p;
}

char *probe_strndup(const char *s, size_t cap)
{
    size_t n = 0;
    while (n < cap && s[n] != '\0') n++;
    char *p = probe_new(n + 1);
    if (p != NULL) { memcpy(p, s, n); p[n] = '\0'; }
    return p;
}

size_t probe_n_alloc(void)     { return g_n_alloc; }
size_t probe_outstanding(void) { return g_outstanding; }
size_t probe_n_badfree(void)   { return g_n_badfree; }
size_t probe_n_requests(void)  { return g_n_requests; }
int    probe_failed(void)      { return g_failed; }

void probe_fail_at(size_t n)
{
    g_fail_at     = n == 0 ? 0 : g_n_requests + n;
    g_failed      = 0;
    g_failed_file = g_failed_func = NULL;
}

void probe_reset(void)
{
    g_outstanding = 0;
    g_n_alloc     = 0;
    g_n_badfree   = 0;
    g_n_requests  = 0;
    g_fail_at     = 0;
    g_failed      = 0;
    g_site_file   = g_site_func   = NULL;
    g_failed_file = g_failed_func = NULL;
    g_n_sited     = 0;
}

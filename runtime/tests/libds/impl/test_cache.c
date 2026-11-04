/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_cache — the engine-owned cache primitive (cache.{c,h}), reached
 * directly; spec/test_cache_spec drives it through the engine.
 *   - ds_cache_clone ([IARC.11.1]): a clone is a fully independent copy, so
 *     the two diverge from the clone point and neither frees the other's
 *     storage.
 *   - with direct now_ns and cap control: lazy TTL expiry, the sweep, cap
 *     enforcement (DS_ERR_CONTRACT_BREACH before mutation), and deterministic
 *     iteration order.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "cache.h"

/* ---- harness --------------------------------------------------------- */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* A live hit whose value equals `want`. */
static bool get_is(ds_cache_t *c, const char *key, uint64_t now, const char *want)
{
    const char *v = NULL;
    if (!ds_cache_get(c, key, now, &v, NULL) || v == NULL) return false;
    return strcmp(v, want) == 0;
}

/* ---- ds_cache_clone: deep copy + divergence -------------------------- */

static void test_clone_deep_copy_and_divergence(void)
{
    ds_cache_t src;
    ds_cache_init(&src);
    ds_cache_set_caps(&src, 16, 4096);

    /* a: no expiry; b: expires at 1000ns; c: no expiry. */
    CHECK(ds_cache_set(&src, "a", "1",   0,    0).status == DS_OK, "set a");
    CHECK(ds_cache_set(&src, "b", "22",  1000, 0).status == DS_OK, "set b");
    CHECK(ds_cache_set(&src, "c", "333", 0,    0).status == DS_OK, "set c");

    ds_cache_t dst;
    ds_cache_init(&dst);
    CHECK(ds_cache_clone(&dst, &src).status == DS_OK, "clone ok");

    /* Structural equality. */
    CHECK(ds_cache_key_count(&dst) == 3, "dst key count");
    CHECK(dst.total_value_bytes == src.total_value_bytes, "dst byte total");
    CHECK(dst.cap_keys == 16 && dst.cap_bytes == 4096, "dst caps carried");

    /* Value + TTL equality (b still live at t=999, expired at t=1000). */
    CHECK(get_is(&dst, "a", 0, "1"),   "dst a");
    CHECK(get_is(&dst, "b", 999, "22"), "dst b live pre-deadline");
    CHECK(get_is(&dst, "c", 0, "333"), "dst c");
    const char *tmp = NULL;
    CHECK(!ds_cache_get(&dst, "b", 1000, &tmp, NULL), "dst b expired at deadline (ttl cloned)");

    /* Divergence: mutate src, dst is untouched. (b was just lazily evicted
       from dst above; re-seed it on src to prove independence cleanly.) */
    CHECK(ds_cache_set(&src, "b", "22", 1000, 0).status == DS_OK, "re-set src b");
    CHECK(ds_cache_set(&src, "a", "999", 0, 0).status == DS_OK, "src a overwrite");
    CHECK(ds_cache_delete(&src, "c"), "src delete c");
    CHECK(get_is(&dst, "a", 0, "1"),   "dst a unchanged by src overwrite");
    CHECK(get_is(&dst, "c", 0, "333"), "dst c unchanged by src delete");

    /* Divergence the other way: mutate dst, src untouched. */
    CHECK(ds_cache_set(&dst, "a", "X", 0, 0).status == DS_OK, "dst a overwrite");
    CHECK(get_is(&src, "a", 0, "999"), "src a unchanged by dst overwrite");

    /* Independent storage — freeing one must not disturb the other. */
    ds_cache_free(&src);
    CHECK(get_is(&dst, "a", 0, "X"), "dst survives src free (deep copy)");
    ds_cache_free(&dst);
}

static void test_clone_empty(void)
{
    ds_cache_t src, dst;
    ds_cache_init(&src);
    ds_cache_init(&dst);
    CHECK(ds_cache_clone(&dst, &src).status == DS_OK, "clone empty ok");
    CHECK(ds_cache_key_count(&dst) == 0, "empty clone has no keys");
    CHECK(dst.total_value_bytes == 0, "empty clone zero bytes");
    ds_cache_free(&src);
    ds_cache_free(&dst);
}

/* ---- lazy TTL expiry (direct now_ns control) ------------------------- */

static void test_ttl_lazy_expiry(void)
{
    ds_cache_t c;
    ds_cache_init(&c);
    CHECK(ds_cache_set(&c, "k", "v", 100, 50).status == DS_OK, "set ttl");  /* deadline 150 */
    CHECK(get_is(&c, "k", 149, "v"), "live before deadline");
    const char *tmp = NULL;
    bool expired = false;
    CHECK(ds_cache_get(&c, "k", 149, &tmp, &expired), "live read is a hit");
    CHECK(!expired, "a live read reports no expiry");
    CHECK(!ds_cache_get(&c, "k", 150, &tmp, &expired), "miss at deadline");
    /* Backstop eviction happened on the expired read → key is gone, and the
       caller was TOLD, so it can notify ([NSTG.2.4.2]). */
    CHECK(expired, "the expired read reports the eviction");
    CHECK(ds_cache_key_count(&c) == 0, "expired entry evicted on read");
    /* A plain miss is not an expiry — the two must not be conflated. */
    CHECK(!ds_cache_get(&c, "absent", 150, &tmp, &expired), "absent key misses");
    CHECK(!expired, "a plain miss reports no expiry");
    /* ttl 0 = no expiry. */
    CHECK(ds_cache_set(&c, "p", "q", 0, 0).status == DS_OK, "set no-ttl");
    CHECK(get_is(&c, "p", (uint64_t)1e18, "q"), "no-ttl never expires");
    ds_cache_free(&c);
}

/* ---- ds_cache_sweep_expired ([NSTG.2.4.2]) ---------------------------- */

typedef struct {
    uint32_t n;
    char     keys[8][8];
} sweep_log_t;

static void sweep_record(void *ctx, const char *key)
{
    sweep_log_t *log = (sweep_log_t *) ctx;
    if (log->n < 8) {
        strncpy(log->keys[log->n], key, 7);
        log->keys[log->n][7] = '\0';
    }
    log->n++;
}

static bool sweep_saw(const sweep_log_t *log, const char *key)
{
    for (uint32_t i = 0; i < log->n && i < 8; i++)
        if (strcmp(log->keys[i], key) == 0) return true;
    return false;
}

/* An entry NOTHING EVER READS AGAIN still leaves, and still notifies. */
static void test_sweep_removes_and_reports_unread_entries(void)
{
    ds_cache_t c;
    ds_cache_init(&c);
    /* deadlines: a=150, b=none, c=150, d=1000 */
    CHECK(ds_cache_set(&c, "a", "1",  100, 50).status == DS_OK, "set a");
    CHECK(ds_cache_set(&c, "b", "22",   0,  0).status == DS_OK, "set b");
    CHECK(ds_cache_set(&c, "c", "333",100, 50).status == DS_OK, "set c");
    CHECK(ds_cache_set(&c, "d", "4",  950, 50).status == DS_OK, "set d");
    size_t bytes_before = c.total_value_bytes;

    sweep_log_t log = {0};
    /* Before any deadline: nothing removed, nothing reported. */
    CHECK(ds_cache_sweep_expired(&c, 149, sweep_record, &log) == 0,
          "no sweep removals before the deadline");
    CHECK(log.n == 0, "no notifications before the deadline");
    CHECK(ds_cache_key_count(&c) == 4, "all four still live");

    /* At the deadline: a and c go, b (no ttl) and d (later) stay. Nothing
       read any of them — that is the whole point. */
    CHECK(ds_cache_sweep_expired(&c, 150, sweep_record, &log) == 2,
          "sweep removed both expired entries");
    CHECK(log.n == 2, "one notification per removed entry");
    CHECK(sweep_saw(&log, "a") && sweep_saw(&log, "c"),
          "notifications name the removed keys");
    CHECK(ds_cache_key_count(&c) == 2, "two entries survive");
    CHECK(get_is(&c, "b", 150, "22"), "no-ttl entry survives the sweep");
    CHECK(get_is(&c, "d", 150, "4"),  "not-yet-expired entry survives");
    /* Byte accounting follows the removals ("1" + "333" = 4 bytes). */
    CHECK(c.total_value_bytes == bytes_before - 4, "byte total tracks the sweep");

    /* Idempotent: a second sweep at the same instant finds nothing. */
    sweep_log_t again = {0};
    CHECK(ds_cache_sweep_expired(&c, 150, sweep_record, &again) == 0,
          "re-sweeping the same instant removes nothing");
    CHECK(again.n == 0, "and notifies nothing");
    ds_cache_free(&c);
}

/* Every entry expiring at once is the case the dense swap-remove can get
   wrong: the last entry fills the hole, so a sweep that advances its index
   after a removal skips whatever moved in. */
static void test_sweep_all_expired_and_null_callback(void)
{
    ds_cache_t c;
    ds_cache_init(&c);
    for (int i = 0; i < 6; i++) {
        char k[8];
        snprintf(k, sizeof(k), "k%d", i);
        CHECK(ds_cache_set(&c, k, "v", 100, 50).status == DS_OK, "set");
    }
    sweep_log_t log = {0};
    CHECK(ds_cache_sweep_expired(&c, 200, sweep_record, &log) == 6,
          "sweep removes every expired entry in one pass");
    CHECK(log.n == 6, "six notifications");
    CHECK(ds_cache_key_count(&c) == 0, "cache empty");
    CHECK(c.total_value_bytes == 0, "byte total back to zero");

    /* A NULL callback is legal — removal still happens (no hook wired is the
       volatile-cache configuration, not an error). */
    CHECK(ds_cache_set(&c, "z", "v", 100, 50).status == DS_OK, "set z");
    CHECK(ds_cache_sweep_expired(&c, 200, NULL, NULL) == 1,
          "NULL callback still removes");
    CHECK(ds_cache_key_count(&c) == 0, "z gone");
    ds_cache_free(&c);
}

/* [LDET.5.11]: several expired entries leave, and are reported, in the order
   their keys were last set. The history below makes the map's dense order
   differ from that: deleting k1 swap-moves k4 into its slot, and re-setting
   k2 restamps it without moving it. Dense order is then k4 k2 k3 k5; set
   order is k3 k4 k5 k2; a walk with swap-remove would report k4 k5 k3 k2, so
   the three orders are distinct. */
static bool sweep_order_is(const sweep_log_t *log, const char *const *want,
                           uint32_t n)
{
    if (log->n != n) return false;
    for (uint32_t i = 0; i < n; i++)
        if (strcmp(log->keys[i], want[i]) != 0) return false;
    return true;
}

static void build_reshuffled(ds_cache_t *c)
{
    ds_cache_init(c);
    CHECK(ds_cache_set(c, "k1", "v", 100, 50).status == DS_OK, "set k1");
    CHECK(ds_cache_set(c, "k2", "v", 100, 50).status == DS_OK, "set k2");
    CHECK(ds_cache_set(c, "k3", "v", 100, 50).status == DS_OK, "set k3");
    CHECK(ds_cache_set(c, "k4", "v", 100, 50).status == DS_OK, "set k4");
    CHECK(ds_cache_delete(c, "k1"), "delete k1 (swap-moves k4)");
    CHECK(ds_cache_set(c, "k5", "v", 100, 50).status == DS_OK, "set k5");
    CHECK(ds_cache_set(c, "k2", "w", 100, 50).status == DS_OK, "re-set k2");
}

/* @spec [LDET.5.11] */
static void test_sweep_order_is_last_set_order(void)
{
    static const char *const want[] = { "k3", "k4", "k5", "k2" };

    ds_cache_t c;
    build_reshuffled(&c);
    /* The precondition the test rests on: dense order is not set order. */
    CHECK(strcmp(ds_cache_entry_at(&c, 0)->key, "k4") == 0,
          "precondition: k4 was swap-moved to the front of the dense order");

    /* A clone carries each entry's set order, so it sweeps the same way. */
    ds_cache_t d;
    ds_cache_init(&d);
    CHECK(ds_cache_clone(&d, &c).status == DS_OK, "clone");

    sweep_log_t log = {0};
    CHECK(ds_cache_sweep_expired(&c, 150, sweep_record, &log) == 4,
          "all four expire");
    CHECK(sweep_order_is(&log, want, 4),
          "removed in last-set order: k3 k4 k5 k2");

    sweep_log_t clog = {0};
    CHECK(ds_cache_sweep_expired(&d, 150, sweep_record, &clog) == 4,
          "all four expire in the clone");
    CHECK(sweep_order_is(&clog, want, 4), "the clone removes in the same order");

    ds_cache_free(&c);
    ds_cache_free(&d);
}

/* ---- cap enforcement: breach BEFORE mutation ------------------------- */

static void test_cap_enforcement(void)
{
    ds_cache_t c;
    ds_cache_init(&c);

    /* cap_keys = 2. */
    ds_cache_set_caps(&c, 2, 0);
    CHECK(ds_cache_set(&c, "a", "1", 0, 0).status == DS_OK, "key 1/2");
    CHECK(ds_cache_set(&c, "b", "1", 0, 0).status == DS_OK, "key 2/2");
    ds_result_t r = ds_cache_set(&c, "c", "1", 0, 0);
    CHECK(r.status == DS_ERR_CONTRACT_BREACH, "3rd new key breaches cap_keys");
    CHECK(ds_cache_key_count(&c) == 2, "breach left cache unmutated");
    const char *tmp = NULL;
    CHECK(!ds_cache_get(&c, "c", 0, &tmp, NULL), "breached key absent");
    /* Overwriting an existing key is not a new key — allowed at cap. */
    CHECK(ds_cache_set(&c, "a", "9", 0, 0).status == DS_OK, "overwrite at cap ok");
    ds_cache_free(&c);

    /* cap_bytes = 5 (value bytes). */
    ds_cache_init(&c);
    ds_cache_set_caps(&c, 0, 5);
    CHECK(ds_cache_set(&c, "a", "123", 0, 0).status == DS_OK, "3 bytes ok");
    CHECK(ds_cache_set(&c, "b", "45", 0, 0).status == DS_OK, "+2 == cap ok");
    r = ds_cache_set(&c, "d", "6", 0, 0);
    CHECK(r.status == DS_ERR_CONTRACT_BREACH, "+1 over cap_bytes breaches");
    CHECK(c.total_value_bytes == 5, "byte total unchanged by breach");
    ds_cache_free(&c);
}

/* ---- [LTIM.1.1.5]: a deadline is never wrapped ------------------------ */

/* The floor under the rule's NOT_REPRESENTABLE: ds_cache_set refuses a
   deadline past INT64_MAX with DS_ERR_TIME_RANGE and leaves the cache as it
   was, breach_cap included. The boundary pinned both ways: a deadline of
   exactly INT64_MAX is written. And a TTL that would wrap the unsigned sum to
   0, the no-expiry sentinel, is refused rather than stored for ever. */
static void test_deadline_past_range_refused(void)
{
    const uint64_t max = (uint64_t) INT64_MAX;
    ds_cache_t c;
    ds_cache_init(&c);
    ds_cache_set_caps(&c, 1, 0);
    CHECK(ds_cache_set(&c, "a", "1", 0, 0).status == DS_OK, "key 1/1");
    CHECK(ds_cache_set(&c, "b", "1", 0, 0).status == DS_ERR_CONTRACT_BREACH,
          "a breach, so breach_cap is set");

    ds_result_t r = ds_cache_set(&c, "a", "2", 2, max - 1);
    CHECK(r.status == DS_ERR_TIME_RANGE, "now + ttl = INT64_MAX + 1 refused");
    CHECK(c.breach_cap == DS_CAP_UNSPECIFIED,
          "the refusal is not reported as the earlier breach");
    CHECK(get_is(&c, "a", 0, "1"), "the refused write left the entry");

    r = ds_cache_set(&c, "a", "3", UINT64_MAX - (max - 1) + 1, max - 1);
    CHECK(r.status == DS_ERR_TIME_RANGE,
          "a TTL that wraps the sum to the no-expiry sentinel is refused");
    CHECK(get_is(&c, "a", 0, "1"), "and leaves the entry");

    r = ds_cache_set(&c, "a", "4", 1, max - 1);
    CHECK(r.status == DS_OK, "now + ttl = INT64_MAX is written");
    CHECK(get_is(&c, "a", max - 1, "4"), "live before its deadline");
    CHECK(!get_is(&c, "a", max, "4"), "and gone at it");

    CHECK(ds_cache_ttl_in_range(max, 0), "no TTL is no deadline, at any now");
    CHECK(!ds_cache_ttl_in_range(max + 1, 1), "a now past the range");
    ds_cache_free(&c);
}

/* ---- deterministic iteration order (Checkpoint / replay requirement) ------- */

static void snapshot_keys(const ds_cache_t *c, char out[][8], uint32_t *n)
{
    uint32_t k = ds_cache_key_count(c);
    *n = k;
    for (uint32_t i = 0; i < k; i++) {
        const ds_cache_entry_t *e = ds_cache_entry_at(c, i);
        strncpy(out[i], e->key, 7);
        out[i][7] = '\0';
    }
}

static void test_entry_at_deterministic_order(void)
{
    ds_cache_t c;
    ds_cache_init(&c);
    ds_cache_set(&c, "k1", "a", 0, 0);
    ds_cache_set(&c, "k2", "a", 0, 0);
    ds_cache_set(&c, "k3", "a", 0, 0);
    ds_cache_set(&c, "k4", "a", 0, 0);
    ds_cache_delete(&c, "k2");
    ds_cache_set(&c, "k5", "a", 0, 0);

    char a[8][8], b[8][8]; uint32_t na, nb;
    snapshot_keys(&c, a, &na);
    snapshot_keys(&c, b, &nb);
    CHECK(na == 4 && nb == 4, "key count after del+insert");
    /* Same history → identical iteration order every time (determinism). */
    bool same = (na == nb);
    for (uint32_t i = 0; i < na && same; i++)
        same = (strcmp(a[i], b[i]) == 0);
    CHECK(same, "iteration order is deterministic across passes");

    /* A clone iterates in the SAME order (Checkpoint-of-a-clone is faithful). */
    ds_cache_t d;
    ds_cache_init(&d);
    CHECK(ds_cache_clone(&d, &c).status == DS_OK, "clone for order check");
    char cc[8][8]; uint32_t nc;
    snapshot_keys(&d, cc, &nc);
    bool clone_same = (nc == na);
    for (uint32_t i = 0; i < na && clone_same; i++)
        clone_same = (strcmp(a[i], cc[i]) == 0);
    CHECK(clone_same, "clone preserves iteration order");

    ds_cache_free(&c);
    ds_cache_free(&d);
}

int main(void)
{
    test_clone_deep_copy_and_divergence();
    test_clone_empty();
    test_ttl_lazy_expiry();
    test_sweep_removes_and_reports_unread_entries();
    test_sweep_all_expired_and_null_callback();
    test_sweep_order_is_last_set_order();
    test_cap_enforcement();
    test_deadline_past_range_refused();
    test_entry_at_deterministic_order();
    if (g_fails == 0) printf("test_cache: OK\n");
    return g_fails != 0;
}

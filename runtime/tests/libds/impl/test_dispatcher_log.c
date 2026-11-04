/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_dispatcher_log — the IMPL path of the `log` verb ([IDSP.2.5]).
 *
 * ds_dispatcher_log() called directly. spec/test_log_spec drives the verb
 * through a compiled .dsc, which cannot reach what the compiler refuses, such
 * as a malformed level; the AOT dispatch table calls this entry point with no
 * compiler in between.
 *
 * [IDSP.2.5] says "all four levels"; the enum has five, and all five are
 * exercised.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "dispatcher.h"

/* ---- harness --------------------------------------------------------- */

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

typedef struct {
    int            n_calls;
    ds_log_level_t last_level;
    char           last_category[64];
    char           last_message[128];
    ds_result_t    next_return;
} log_probe_t;

static ds_result_t log_cb(ds_engine_t *engine, const ds_log_event_t *ev, void *user)
{
    (void) engine;
    log_probe_t *p = (log_probe_t *) user;
    p->n_calls++;
    p->last_level = ev->level;
    p->last_category[0] = '\0';
    p->last_message[0]  = '\0';
    if (ev->category) strncpy(p->last_category, ev->category,
                              sizeof(p->last_category) - 1);
    if (ev->message)  strncpy(p->last_message, ev->message,
                              sizeof(p->last_message) - 1);
    return p->next_return;
}

static ds_engine_t *new_engine(void)
{
    ds_engine_t *e = NULL;
    ds_result_t  r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK || e == NULL) {
        fprintf(stderr, "FAIL: ds_engine_new: status=%d (%s)\n",
                r.status, r.detail ? r.detail : "(null)");
        return NULL;
    }
    return e;
}

/* ---- every level reaches the callback, unchanged --------------------- */

static void test_all_levels(void)
{
    static const ds_log_level_t levels[] = {
        DS_LOG_DEBUG, DS_LOG_INFO, DS_LOG_WARNING, DS_LOG_ERROR, DS_LOG_CRITICAL,
    };
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    log_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_set_log_callback(e, log_cb, &p).status == DS_OK,
          "set_log_callback");

    for (size_t i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
        ds_result_t r = ds_dispatcher_log(e, levels[i], "rule_a", "hello");
        CHECK(r.status == DS_OK, "dispatcher_log returns OK");
        CHECK((size_t) p.n_calls == i + 1, "callback fired once per call");
        CHECK(p.last_level == levels[i], "level round-trips unchanged");
        CHECK(strcmp(p.last_message, "hello") == 0, "message round-trips");
        /* The category is the RULE NAME: the DS verb has no category
           argument. */
        CHECK(strcmp(p.last_category, "rule_a") == 0, "category is the rule name");
    }
    ds_engine_free(e);
}

/* ---- a malformed level is REJECTED, and reaches nothing -------------- */

static void test_malformed_level(void)
{
    /* [IDSP.2.5]'s "level-must-be-valid": refused, not clamped to INFO. */
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    log_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_set_log_callback(e, log_cb, &p).status == DS_OK,
          "set_log_callback");

    ds_result_t r1 = ds_dispatcher_log(e, (ds_log_level_t) (DS_LOG_CRITICAL + 1),
                                       "rule_a", "past the end");
    CHECK(r1.status == DS_ERR_INVAL, "one past CRITICAL is refused");
    CHECK(p.n_calls == 0, "and never reaches the callback");

    ds_result_t r2 = ds_dispatcher_log(e, (ds_log_level_t) 999, "rule_a", "far out");
    CHECK(r2.status == DS_ERR_INVAL, "a far out-of-range level is refused too");
    CHECK(p.n_calls == 0, "still nothing delivered");

    /* The boundaries themselves stay valid — an off-by-one in the check would
       silently cost DEBUG or CRITICAL, and test_all_levels above would not
       necessarily catch a one-sided slip. */
    CHECK(ds_dispatcher_log(e, DS_LOG_DEBUG, "rule_a", "lo").status == DS_OK,
          "DEBUG, the low boundary, is still accepted");
    CHECK(ds_dispatcher_log(e, DS_LOG_CRITICAL, "rule_a", "hi").status == DS_OK,
          "CRITICAL, the high boundary, is still accepted");
    CHECK(p.n_calls == 2, "and both were delivered");

    ds_engine_free(e);
}

/* ---- NULL message is dropped, and is not an error -------------------- */

static void test_null_message(void)
{
    /* A NULL message is dropped. A NULL rule_name becomes "", so the category
     * is always a valid string for the callback. */
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    log_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_set_log_callback(e, log_cb, &p).status == DS_OK, "attach");

    CHECK(ds_dispatcher_log(e, DS_LOG_INFO, "rule_a", NULL).status == DS_OK,
          "NULL message is OK");
    CHECK(p.n_calls == 0, "NULL message delivers nothing");

    CHECK(ds_dispatcher_log(e, DS_LOG_INFO, NULL, "orphan").status == DS_OK,
          "NULL rule_name is OK");
    CHECK(p.n_calls == 1, "NULL rule_name still delivers");
    CHECK(p.last_category[0] == '\0', "NULL rule_name becomes an empty category");

    ds_engine_free(e);
}

/* ---- no callback registered is a silent drop, not an error ----------- */

static void test_null_cb_silent_drop(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    /* Never registered. */
    ds_result_t r = ds_dispatcher_log(e, DS_LOG_INFO, "rule_a", "into the void");
    CHECK(r.status == DS_OK, "log with no callback is OK, not an error");

    /* Registered, then removed with cb=NULL — the documented way to detach. */
    log_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_set_log_callback(e, log_cb, &p).status == DS_OK, "attach");
    CHECK(ds_dispatcher_log(e, DS_LOG_INFO, "rule_a", "seen").status == DS_OK,
          "log while attached");
    CHECK(p.n_calls == 1, "delivered while attached");
    CHECK(ds_engine_set_log_callback(e, NULL, NULL).status == DS_OK, "detach");
    CHECK(ds_dispatcher_log(e, DS_LOG_INFO, "rule_a", "unseen").status == DS_OK,
          "log after detach is OK");
    CHECK(p.n_calls == 1, "nothing delivered after detach");
    ds_engine_free(e);
}

/* ---- the callback's error is DROPPED ([NCBK.1.5]) --------------------- */

/* [NCBK.1.5]: the log callback is fire-and-forget, so a failing one is still
   called and its status goes nowhere. */
static void test_cb_error_is_dropped(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    log_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_ERR_IO };
    CHECK(ds_engine_set_log_callback(e, log_cb, &p).status == DS_OK, "attach");

    ds_result_t r = ds_dispatcher_log(e, DS_LOG_ERROR, "rule_a", "boom");
    CHECK(p.n_calls == 1, "callback was still invoked");
    CHECK(r.status == DS_OK, "the callback's status is dropped ([NCBK.1.5])");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_dispatcher_log ===\n");
    test_all_levels();
    test_malformed_level();
    test_null_message();
    test_null_cb_silent_drop();
    test_cb_error_is_dropped();
    if (g_fails) {
        fprintf(stderr, "test_dispatcher_log: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_dispatcher_log: ALL PASSED ===\n");
    return 0;
}

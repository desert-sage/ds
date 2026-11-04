/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.10.4]
 * The engine refuses the whole FactExternal, asserting nothing, with
 * DS_ERR_PARSE when "a text field at any depth ... is not well-formed UTF-8".
 *
 * THE PATH: ds_engine_assert_external -> fx_deliver -> fx_scan_nul, ahead of
 * the unpack, the plan and the call's sample ([STYL.5.10.8]).
 *
 * A sender's rules publish a `Ref`, a `Main` that inlines a `Ref`, and an
 * `Out` holding a Json value, so the bytes are the ones another tier is really
 * handed (DS_EV_ACTION_PUBLISH). A `publish` puts nothing in the sender's
 * working memory ([LTIE.4.3]), so the `Ref` that `Main` refers to is one the
 * sender's host asserts. One byte of each is then set to a lone 0xFF:
 *
 *   the received fact's String, an inlined copy's String, a Json field's text,
 *   the record's schema name, and an Arg's name.
 *
 * For each: DS_ERR_PARSE, ds_engine_fact_count unchanged, and no stream event,
 * which a call's sample would be (DS_EV_TICK). THE CONTROL: each of the three
 * records unpatched is admitted, asserts its facts and does record its sample,
 * so each refusal is the planted byte's and the event count can move. `Out` is
 * the one record carrying a Json value, so its control is what makes the Json
 * case a test of the scan.
 */
#include "spec_common.h"

static const char *PROGRAM =
    "schema Src scope logical:\n"
    "    id: String key\n"
    "    note: String mutable\n"
    "\n"
    "schema Ref scope logical:\n"
    "    id: String key\n"
    "    note: String mutable\n"
    "\n"
    "schema Mk scope logical:\n"
    "    k: Int key\n"
    "\n"
    "schema Main scope logical:\n"
    "    k: Int key\n"
    "    r: Ref mutable\n"
    "\n"
    "schema Holder scope logical:\n"
    "    k: Int key\n"
    "    body: Json mutable\n"
    "\n"
    "schema Out scope logical:\n"
    "    k: Int key\n"
    "    body: Json mutable\n"
    "\n"
    "rule send_ref:\n"
    "    Src s\n"
    "->\n"
    "    publish Ref id: s.id note: s.note\n"
    "\n"
    "rule send_main:\n"
    "    Mk m\n"
    "    Ref r\n"
    "->\n"
    "    publish Main k: m.k r: r\n"
    "\n"
    "rule send_out:\n"
    "    Holder h\n"
    "->\n"
    "    publish Out k: h.k body: h.body\n";

#define RECORD_MAX 1024u

typedef struct {
    uint8_t bytes[RECORD_MAX];
    size_t  len;
} record_t;

typedef struct {
    record_t ref, main, out;
} published_t;

/* Copy each record out of the callback ([NCBK.10.1]), by the fact's schema. */
static ds_result_t on_publish(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    published_t *p = user;
    if (ev->kind != DS_EV_ACTION_PUBLISH) return DS_OK_R;
    const ds_schema_t *schema = NULL;
    const char *name = NULL;
    ds_result_t r = ds_fact_get_schema(ev->p.action_publish.fact, &schema);
    if (r.status != DS_OK) return r;
    r = ds_schema_get_name(schema, &name);
    if (r.status != DS_OK) return r;
    record_t *to = strcmp(name, "Ref") == 0 ? &p->ref
                 : strcmp(name, "Main") == 0 ? &p->main
                 : strcmp(name, "Out") == 0 ? &p->out : NULL;
    if (to != NULL && ev->p.action_publish.external_len <= RECORD_MAX) {
        memcpy(to->bytes, ev->p.action_publish.external,
               ev->p.action_publish.external_len);
        to->len = ev->p.action_publish.external_len;
    }
    return DS_OK_R;
}

static int publish_all(published_t *p)
{
    ds_engine_t *e = NULL;
    ds_json_t *tree = NULL;
    const ds_schema_t *src = NULL, *ref = NULL, *mk = NULL, *holder = NULL;
    EXPECT_OK("sender", ds_engine_new(NULL, &e));
    EXPECT_OK("sender load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("sender stream", ds_engine_set_stream_callback(e, on_publish, p));
    EXPECT_OK("find Src", ds_engine_schema_find(e, "Src", &src));
    EXPECT_OK("find Ref", ds_engine_schema_find(e, "Ref", &ref));
    EXPECT_OK("find Mk", ds_engine_schema_find(e, "Mk", &mk));
    EXPECT_OK("find Holder", ds_engine_schema_find(e, "Holder", &holder));

    ds_slot_value_t sv[2];
    memset(sv, 0, sizeof sv);
    sv[0].kind = DS_SLOT_STRING; sv[0].v.s = "r1";
    sv[1].kind = DS_SLOT_STRING; sv[1].v.s = "heZlo";
    EXPECT_OK("assert Src", ds_engine_assert(e, src, sv, 2, NULL));
    EXPECT_OK("pump Src", ds_engine_pump(e));
    /* The `Ref` that `Main` refers to: the published one is in no working
       memory here ([LTIE.4.3]). */
    EXPECT_OK("assert Ref", ds_engine_assert(e, ref, sv, 2, NULL));

    ds_slot_value_t mv;
    memset(&mv, 0, sizeof mv);
    mv.kind = DS_SLOT_INT; mv.v.i = 1;
    EXPECT_OK("assert Mk", ds_engine_assert(e, mk, &mv, 1, NULL));

    EXPECT_OK("the Json value", ds_json_new_string("jsZon", 5, &tree));
    ds_slot_value_t hv[2];
    memset(hv, 0, sizeof hv);
    hv[0].kind = DS_SLOT_INT;  hv[0].v.i = 1;
    hv[1].kind = DS_SLOT_JSON; hv[1].v.json = tree;
    EXPECT_OK("assert Holder", ds_engine_assert(e, holder, hv, 2, NULL));
    EXPECT_OK("pump", ds_engine_pump(e));
    EXPECT_OK("free the tree", ds_json_free(tree));
    EXPECT_OK("sender free", ds_engine_free(e));

    if (p->ref.len == 0 || p->main.len == 0 || p->out.len == 0) {
        fprintf(stderr, "FAIL: premise: published Ref %zu, Main %zu, Out %zu bytes\n",
                p->ref.len, p->main.len, p->out.len);
        return 1;
    }
    return 0;
}

static int g_events;
static int g_ticks;

static ds_result_t count_events(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e; (void) user;
    g_events++;
    if (ev->kind == DS_EV_TICK) g_ticks++;
    return DS_OK_R;
}

/* A fresh receiver, handed the record. */
static int deliver(const uint8_t *bytes, size_t len, ds_status_t want,
                   size_t *out_facts, const char *what)
{
    ds_engine_t *e = NULL;
    EXPECT_OK("receiver", ds_engine_new(NULL, &e));
    EXPECT_OK("receiver load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("receiver stream", ds_engine_set_stream_callback(e, count_events, NULL));
    g_events = 0;
    g_ticks = 0;
    EXPECT_STATUS(what, ds_engine_assert_external(e, bytes, len), want);
    EXPECT_OK("fact_count", ds_engine_fact_count(e, out_facts));
    EXPECT_OK("receiver free", ds_engine_free(e));
    return 0;
}

/* The record as published, handed to a fresh receiver: admitted, `want_facts`
   asserted, and the call's one sample recorded. */
static int admitted(const record_t *rec, size_t want_facts, const char *what)
{
    size_t facts = 0;
    if (deliver(rec->bytes, rec->len, DS_OK, &facts, what)) return 1;
    if (facts != want_facts || g_ticks != 1) {
        fprintf(stderr, "FAIL: %s: %zu facts and %d ticks, want %zu and 1\n",
                what, facts, g_ticks, want_facts);
        return 1;
    }
    return 0;
}

/* The record with the byte `at` past the first `text` set to 0xFF, handed to a
   fresh receiver: refused, and nothing changed. */
static int refused(const record_t *rec, const char *text, size_t at, const char *what)
{
    const size_t n = strlen(text);
    uint8_t bad[RECORD_MAX];
    memcpy(bad, rec->bytes, rec->len);
    size_t i = 0;
    while (i + n <= rec->len && memcmp(bad + i, text, n) != 0) i++;
    if (i + n > rec->len) {
        fprintf(stderr, "FAIL: %s: `%s` is not in the record\n", what, text);
        return 1;
    }
    bad[i + at] = 0xFFu;

    size_t facts = 1;
    if (deliver(bad, rec->len, DS_ERR_PARSE, &facts, what)) return 1;
    if (facts != 0 || g_events != 0) {
        fprintf(stderr, "FAIL: %s: %zu facts and %d stream events, want none\n",
                what, facts, g_events);
        return 1;
    }
    return 0;
}

int main(void)
{
    static published_t p;
    if (publish_all(&p)) return 1;

    /* The control: unpatched, each is admitted, and the call's sample shows. */
    if (admitted(&p.ref, 1, "the control: Ref")) return 1;
    if (admitted(&p.main, 2, "the control: Main and its inlined Ref")) return 1;
    if (admitted(&p.out, 1, "the control: Out")) return 1;

    if (refused(&p.ref, "heZlo", 2, "the received fact's String")) return 1;
    if (refused(&p.main, "heZlo", 2, "an inlined copy's String")) return 1;
    if (refused(&p.out, "jsZon", 2, "a Json field's text")) return 1;
    if (refused(&p.ref, "Ref", 1, "the schema name")) return 1;
    if (refused(&p.ref, "note", 1, "an Arg's name")) return 1;

    printf("test_ncbk_10_4__ill_formed_text_is_a_parse_refusal: OK\n");
    return 0;
}

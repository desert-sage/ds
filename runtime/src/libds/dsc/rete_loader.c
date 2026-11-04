/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/rete_loader.c — decode AlphaNode/BetaNode/TerminalNode DSC atoms and load them
 * into the DS Rete engine ([RDSC.4a], [IRET.15]).
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "ds_alloc.h"
#include "ds_pb_alloc.h"
#include "ds_text.h"
#include "rete/action.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "fn.h"            /* ds_lookup_fn — load-time builtin-op validation */
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/val.h"

#include "alfa.pb-c.h"
#include "beta.pb-c.h"
#include "term.pb-c.h"
#include "rete_expr.pb-c.h"

#include "rete_loader.h"

/* With `re` NULL a decoder makes every refusal it makes with one, in the same
   order, and touches no engine: the walk's check, ds_dsc_rete_body_decodes. */

/* ---- Expr tree decoder ------------------------------------------- */

/* [RDSC.11.3]. Also bounds the parse: rdsc_11_4_gate refuses a deeper body before
   protobuf-c, which has no recursion bound, unpacks it. */
#define EXPR_MAX_DEPTH 48

static ds_result_t decode_expr_msg(const Ds__V1__Expr *msg,
                                   ds_rete_engine_t *re, int depth,
                                   ds_rete_expr_t **out);

static ds_result_t decode_expr_array(Ds__V1__Expr **items, size_t n,
                                     ds_rete_engine_t *re, int depth,
                                     ds_rete_expr_t ***out_items,
                                     uint32_t *out_count)
{
    *out_items = NULL;
    *out_count = 0;
    if (n == 0) return DS_OK_R;

    ds_rete_expr_t **arr = DS_CALLOC(n, sizeof(*arr));
    if (!arr) return DS_ERR_R(DS_ERR_OOM, "rete_loader: expr array alloc");

    for (size_t i = 0; i < n; i++) {
        ds_result_t r = decode_expr_msg(items[i], re, depth + 1, &arr[i]);
        if (r.status != DS_OK) {
            for (size_t j = 0; j < i; j++)
                ds_rete_expr_free_tree(arr[j]);
            DS_FREE(arr);
            return r;
        }
    }
    *out_items = arr;
    *out_count = (uint32_t) n;
    return DS_OK_R;
}

/* A required operand: an absent one is refused ([RDSC.11.1]). */
static ds_result_t decode_child(const Ds__V1__Expr *child,
                                ds_rete_engine_t *re, int depth,
                                ds_rete_expr_t **out)
{
    *out = NULL;
    if (!child)
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "rete_loader: expr operand absent");
    return decode_expr_msg(child, re, depth + 1, out);
}

static ds_result_t intern_text(ds_rete_engine_t *re, const char *s,
                               const char **out, uint32_t *len)
{
    if (re == NULL) {
        *out = NULL;
        *len = 0;
        return DS_OK_R;
    }
    ds_result_t r = ds_rete_intern_cstr(re->intern, s ? s : "", out);
    *len = (r.status == DS_OK) ? (uint32_t) strlen(*out) : 0;
    return r;
}

#define SEMANTIC(msg) DS_ERR_R(DS_ERR_DSC_SEMANTIC, "rete_loader: " msg)

/* [RLOW.6.4], [IARC.1.16]: only enumerations the renderer has no meaning for are
   refused here. How a spec's parts combine with its type, and which value kind it
   meets, are the compiler's ([LGRA.2.9.6.5]). */
static ds_result_t decode_interp(const Ds__V1__InterpExpr *m,
                                 ds_rete_engine_t *re, int depth,
                                 ds_rete_expr_t *node)
{
    if (m == NULL || m->n_prims == 0) return DS_OK_R;   /* "" */
    node->interp.prims = DS_CALLOC(m->n_prims, sizeof(*node->interp.prims));
    if (node->interp.prims == NULL)
        return DS_ERR_R(DS_ERR_OOM, "rete_loader: interp prims alloc");
    node->interp.prim_count = (uint32_t) m->n_prims;

    for (size_t i = 0; i < m->n_prims; i++) {
        const Ds__V1__FormatPrim *fp = m->prims[i];
        ds_rete_fprim_t *p = &node->interp.prims[i];
        ds_result_t r = DS_OK_R;
        switch (fp ? fp->prim_case : DS__V1__FORMAT_PRIM__PRIM__NOT_SET) {
        case DS__V1__FORMAT_PRIM__PRIM_TEXT:
            p->kind = DS_RETE_FPRIM_TEXT;
            r = intern_text(re, fp->text, &p->text, &p->text_len);
            break;

        case DS__V1__FORMAT_PRIM__PRIM_VALUE: {
            const Ds__V1__ValuePrim *v = fp->value;
            p->kind = DS_RETE_FPRIM_VALUE;
            uint32_t align = (uint32_t) v->align, type = (uint32_t) v->type;
            if (align > DS_RETE_FALIGN_RIGHT)
                return SEMANTIC("interp alignment out of range");
            if (type > DS_RETE_FTYPE_B)
                return SEMANTIC("interp type out of range");
            p->align = (ds_rete_falign_t) align;
            p->type  = (ds_rete_ftype_t) type;
            p->plus  = v->plus;
            p->zero  = v->zero;
            p->width = v->width;
            p->has_precision = v->has_precision;
            p->precision     = v->precision;
            r = decode_child(v->value, re, depth, &p->value);
            break;
        }

        case DS__V1__FORMAT_PRIM__PRIM_TIME: {
            const Ds__V1__TimePrim *t = fp->time;
            p->kind = DS_RETE_FPRIM_TIME;
            if (t->n_items > 0) {
                p->items = DS_CALLOC(t->n_items, sizeof(*p->items));
                if (p->items == NULL)
                    return DS_ERR_R(DS_ERR_OOM, "rete_loader: interp items alloc");
                p->item_count = (uint32_t) t->n_items;
            }
            for (size_t k = 0; k < t->n_items && r.status == DS_OK; k++) {
                const Ds__V1__TimeItem *it = t->items[k];
                ds_rete_titem_t *dst = &p->items[k];
                if (it && it->item_case == DS__V1__TIME_ITEM__ITEM_TEXT) {
                    r = intern_text(re, it->text, &dst->text, &dst->text_len);
                } else if (it && it->item_case == DS__V1__TIME_ITEM__ITEM_FIELD) {
                    uint32_t f = (uint32_t) it->field;
                    if (f < DS_RETE_TFIELD_YEAR || f > DS_RETE_TFIELD_UTC_OFFSET)
                        return SEMANTIC("interp time field unspecified or out of range");
                    dst->field = (ds_rete_tfield_t) f;
                } else {
                    return SEMANTIC("interp time item with neither text nor field");
                }
            }
            if (r.status != DS_OK) break;
            r = decode_child(t->value, re, depth, &p->value);
            break;
        }

        default:
            return SEMANTIC("interp primitive with no case set");
        }
        if (r.status != DS_OK) return r;
    }
    return DS_OK_R;
}

#undef SEMANTIC

static ds_result_t decode_expr_msg(const Ds__V1__Expr *msg,
                                   ds_rete_engine_t *re, int depth,
                                   ds_rete_expr_t **out)
{
    *out = NULL;
    if (depth > EXPR_MAX_DEPTH)
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "rete_loader: Expr nested deeper than 48 (RDSC.11.3)");
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, "rete_loader: missing expr");

    ds_rete_expr_kind_t kind;
    switch (msg->kind_case) {
    case DS__V1__EXPR__KIND_LIT_INT:   kind = DS_RETE_EXPR_LIT_INT;   break;
    case DS__V1__EXPR__KIND_LIT_FLOAT: kind = DS_RETE_EXPR_LIT_FLOAT; break;
    case DS__V1__EXPR__KIND_LIT_STR:   kind = DS_RETE_EXPR_LIT_STR;   break;
    case DS__V1__EXPR__KIND_LIT_BOOL:  kind = DS_RETE_EXPR_LIT_BOOL;  break;
    case DS__V1__EXPR__KIND_VAR:       kind = DS_RETE_EXPR_VAR;       break;
    case DS__V1__EXPR__KIND_BINOP:     kind = DS_RETE_EXPR_BINOP;     break;
    case DS__V1__EXPR__KIND_UNOP:      kind = DS_RETE_EXPR_UNOP;      break;
    case DS__V1__EXPR__KIND_CALL:      kind = DS_RETE_EXPR_CALL;      break;
    case DS__V1__EXPR__KIND_INTERP:    kind = DS_RETE_EXPR_INTERP;    break;
    case DS__V1__EXPR__KIND_NOW:       kind = DS_RETE_EXPR_NOW;       break;
    case DS__V1__EXPR__KIND_IF_:       kind = DS_RETE_EXPR_IF;        break;
    case DS__V1__EXPR__KIND_BIND:      kind = DS_RETE_EXPR_BIND;      break;
    case DS__V1__EXPR__KIND_BIND_REF:  kind = DS_RETE_EXPR_BIND_REF;  break;
    case DS__V1__EXPR__KIND_JSON_PATH: kind = DS_RETE_EXPR_JSON_PATH; break;
    case DS__V1__EXPR__KIND_LIT_NULL:  kind = DS_RETE_EXPR_LIT_NULL;  break;
    case DS__V1__EXPR__KIND_COALESCE:  kind = DS_RETE_EXPR_COALESCE;  break;
    case DS__V1__EXPR__KIND_IS_TEST:   kind = DS_RETE_EXPR_IS_TEST;   break;
    case DS__V1__EXPR__KIND_ENTRY_STAMP: kind = DS_RETE_EXPR_ENTRY_STAMP; break;
    case DS__V1__EXPR__KIND__NOT_SET:
    default:
        /* [RDSC.11.3] */
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "rete_loader: Expr with no kind set");
    }

    /* [RDSC.4a.9.3]: every CallExpr passes through here. On the winning oneof arm
       only: a `call` that lost to a later arm is not this expression. */
    if (kind == DS_RETE_EXPR_CALL) {
        if (!msg->call)
            return DS_ERR_R(DS_ERR_DSC_DECODE,
                            "rete_loader: CALL expr with no CallExpr body");
        if (ds_lookup_fn((uint32_t) msg->call->op) == NULL)
            return DS_ERR_R(DS_ERR_FN_NOT_FOUND,
                            "rete_loader: unknown builtin op in CALL expr");
    }

    ds_rete_expr_t *node = ds_rete_expr_alloc(kind);
    if (!node) return DS_ERR_R(DS_ERR_OOM, "rete_loader: expr node alloc");

    node->json_tainted = msg->json_tainted;

    ds_result_t r = DS_OK_R;

    switch (kind) {
    case DS_RETE_EXPR_LIT_INT:
        node->lit_int = msg->lit_int;
        break;

    case DS_RETE_EXPR_LIT_FLOAT:
        /* [RDSC.9.10], on the winning member only. */
        if (rdsc_9_10_nan(msg->lit_float)) {
            r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                         "rete_loader: Expr.lit_float is a NaN (RDSC.9.10)");
            break;
        }
        node->lit_float = msg->lit_float;
        break;

    case DS_RETE_EXPR_LIT_STR:
        if (re != NULL)
            r = ds_rete_intern_cstr(re->intern, msg->lit_str, &node->lit_str);
        break;

    case DS_RETE_EXPR_LIT_BOOL:
        node->lit_bool = (msg->lit_bool != 0);
        break;

    case DS_RETE_EXPR_LIT_NULL:      /* [LNUL.2.1] — the oneof CASE is the value */
    case DS_RETE_EXPR_NOW:
        break;

    case DS_RETE_EXPR_VAR:
        /* [RDSC.4a.9.1]: an index is a byte, and 255 the marker in both fields. */
        if (msg->var->pattern_index > DS_RETE_VAR_RIGHT_FACT
            || msg->var->slot_index > DS_RETE_VAR_WHOLE_FACT) {
            r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                         "rete_loader: VarExpr index past 255 (RDSC.4a.9.1)");
            break;
        }
        node->var.pattern_index = (uint8_t) msg->var->pattern_index;
        node->var.slot_index    = (uint8_t) msg->var->slot_index;
        break;

    case DS_RETE_EXPR_ENTRY_STAMP:
        /* [LTIM.2.8.6], [RDSC.4a.9.1] */
        if (msg->entry_stamp > DS_RETE_VAR_RIGHT_FACT) {
            r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                         "rete_loader: entry_stamp pattern index past 255 "
                         "(RDSC.4a.9.1)");
            break;
        }
        node->entry_stamp.pattern_index = (uint8_t) msg->entry_stamp;
        break;

    case DS_RETE_EXPR_BINOP:
        node->binop.op = (ds_rete_binop_t) msg->binop->op;
        r = decode_child(msg->binop->left, re, depth, &node->binop.left);
        if (r.status != DS_OK) break;
        r = decode_child(msg->binop->right, re, depth, &node->binop.right);
        break;

    case DS_RETE_EXPR_UNOP:
        node->unop.op = (ds_rete_unop_t) msg->unop->op;
        r = decode_child(msg->unop->operand, re, depth, &node->unop.operand);
        break;

    case DS_RETE_EXPR_CALL:
        node->call.op = (uint32_t) msg->call->op;
        r = decode_expr_array(msg->call->args, msg->call->n_args, re, depth,
                              &node->call.args, &node->call.arg_count);
        break;

    case DS_RETE_EXPR_INTERP:        /* RLOW.6.4 */
        r = decode_interp(msg->interp, re, depth, node);
        break;

    case DS_RETE_EXPR_IF:
        r = decode_child(msg->if_->cond, re, depth, &node->if_.cond);
        if (r.status != DS_OK) break;
        r = decode_child(msg->if_->then_, re, depth, &node->if_.then_);
        if (r.status != DS_OK) break;
        r = decode_child(msg->if_->else_, re, depth, &node->if_.else_);
        break;

    case DS_RETE_EXPR_BIND:
        node->bind.bind_index = msg->bind->bind_index;
        r = decode_child(msg->bind->expr, re, depth, &node->bind.expr);
        break;

    case DS_RETE_EXPR_BIND_REF:
        node->bind_ref.bind_index = msg->bind_ref;
        break;

    case DS_RETE_EXPR_JSON_PATH:
        r = decode_child(msg->json_path->val, re, depth, &node->json_path.val);
        if (r.status != DS_OK) break;
        r = decode_child(msg->json_path->path, re, depth, &node->json_path.path);
        break;

    case DS_RETE_EXPR_COALESCE:      /* [LNUL.8.9] */
        r = decode_child(msg->coalesce->left, re, depth, &node->coalesce.left);
        if (r.status != DS_OK) break;
        r = decode_child(msg->coalesce->right, re, depth, &node->coalesce.right);
        break;

    case DS_RETE_EXPR_IS_TEST: {     /* [LNUL.4.9] */
        /* [LNUL.4.9]: a closed set of subjects, so the proto3 zero is refused too. */
        uint32_t subj = (uint32_t)msg->is_test->subject;
        if (subj < DS_RETE_IS_NULL || subj > DS_RETE_IS_JSON) {
            r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                         "rete_loader: is_test subject out of range");
            break;
        }
        node->is_test.subject = (ds_rete_is_subject_t)subj;
        node->is_test.negated = msg->is_test->negated;
        r = decode_child(msg->is_test->operand, re, depth,
                         &node->is_test.operand);
        break;
    }
    }

    if (r.status != DS_OK) {
        ds_rete_expr_free_tree(node);
        return r;
    }

    *out = node;
    return DS_OK_R;
}

/* fuzz-dsc's pinned verdicts quote these refusals. */
static const char ALFA_UNDECODABLE[] = "rete_loader: alfa body protobuf decode failed";
static const char BETA_UNDECODABLE[] = "rete_loader: beta body protobuf decode failed";
static const char TERM_UNDECODABLE[] = "rete_loader: term body protobuf decode failed";

/* [RDSC.9.5], [RDSC.11.4]: a non-repeated message field met twice is refused
   before protobuf-c unpacks the body. Mercury: `ds.dsc_judge`. */
static const char ALFA_REPEATED[] =
    "dsc: AlphaNode body holds a message field that is not repeated more "
    "than once";
static const char BETA_REPEATED[] =
    "dsc: BetaNode body holds a message field that is not repeated more "
    "than once";
static const char TERM_REPEATED[] =
    "dsc: TerminalNode body holds a message field that is not repeated more "
    "than once";

static const char ALFA_BAD_STRING[] =
    "dsc: AlphaNode body holds a string field that is not well-formed UTF-8 "
    "or holds U+0000 (RDSC.9.12)";
static const char BETA_BAD_STRING[] =
    "dsc: BetaNode body holds a string field that is not well-formed UTF-8 "
    "or holds U+0000 (RDSC.9.12)";
static const char TERM_BAD_STRING[] =
    "dsc: TerminalNode body holds a string field that is not well-formed "
    "UTF-8 or holds U+0000 (RDSC.9.12)";

static const char EXPR_TOO_DEEP[] =
    "rete_loader: Expr nested deeper than 48 (RDSC.11.3)";

/* [RDSC.11.4]: asked before every protobuf-c unpack of a network body. */
static ds_result_t rdsc_11_4_gate(const ProtobufCMessageDescriptor *desc,
                                  const uint8_t *data, size_t len,
                                  const char *undecodable, const char *repeated,
                                  const char *bad_string)
{
    switch (ds_pb_rdsc_11_4_judge(desc, &ds__v1__expr__descriptor,
                                  (unsigned) EXPR_MAX_DEPTH, data, len)) {
    case DS_PB_JUDGE_DECODES:
        return DS_OK_R;
    case DS_PB_JUDGE_REPEATED:
        return DS_ERR_R(DS_ERR_DSC_DECODE, repeated);
    case DS_PB_JUDGE_BAD_STRING:
        return DS_ERR_R(DS_ERR_DSC_DECODE, bad_string);
    case DS_PB_JUDGE_TOO_DEEP:
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC, EXPR_TOO_DEEP);
    case DS_PB_JUDGE_UNDECODABLE:
    default:
        return DS_ERR_R(DS_ERR_DSC_DECODE, undecodable);
    }
}

/* ---- AlphaNode atom decoder ------------------------------------------- */

static ds_result_t decode_alfa(const uint8_t *data, size_t len,
                                ds_rete_engine_t *re,
                                ds_alfa_atom_t *out_atom,
                                ds_retp_alpha_test_t **out_tests)
{
    ds_result_t gate = rdsc_11_4_gate(&ds__v1__alpha_node__descriptor, data,
                                      len, ALFA_UNDECODABLE, ALFA_REPEATED,
                                      ALFA_BAD_STRING);
    if (gate.status != DS_OK) return gate;
    Ds__V1__AlphaNode *msg =
        ds__v1__alpha_node__unpack(&ds_pb_allocator, len, data);
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, ALFA_UNDECODABLE);

    char                 *schema_name = NULL;
    ds_retp_alpha_test_t *tests       = NULL;
    uint32_t              test_count  = 0;
    ds_result_t           r           = DS_OK_R;

    out_atom->node_id = msg->node_id;

    if (msg->node_id == 0) {
        r = DS_ERR_R(DS_ERR_RETP_INVALID,
                     "rete_loader: AlphaNode node_id 0 is reserved (RDSC.4a.3)");
        goto done;
    }
    if (msg->schema_name[0] == '\0') {
        r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                     "rete_loader: AlphaNode names no schema (RDSC.4a.6)");
        goto done;
    }

    schema_name = DS_STRDUP(msg->schema_name);
    if (!schema_name) {
        r = DS_ERR_R(DS_ERR_OOM, "rete_loader: alfa schema_name");
        goto done;
    }

    if (msg->n_tests) {
        tests = DS_CALLOC(msg->n_tests, sizeof(*tests));
        if (!tests) {
            r = DS_ERR_R(DS_ERR_OOM, "rete_loader: alfa tests alloc");
            goto done;
        }
    }

    for (size_t i = 0; i < msg->n_tests; i++) {
        const Ds__V1__AlphaTest *t = msg->tests[i];
        ds_retp_alpha_test_t    *o = &tests[test_count];

        /* [RDSC.4a.6.1]: the slot, then the kind and what that kind needs. */
        const bool has_literal = t->literal != NULL
            && t->literal->value_case != DS__V1__ALPHA_LITERAL__VALUE__NOT_SET;
        const char *malformed = NULL;
        if (t->slot_index >= DS_RETE_VAR_WHOLE_FACT) {
            malformed = "rete_loader: AlphaTest slot_index above 254 "
                        "(RDSC.4a.6.1)";
        } else {
            switch (t->kind) {
            case DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_EQ:
                /* `op` is not read. */
                if (!has_literal)
                    malformed = "rete_loader: AlphaTest EQ with no literal "
                                "(RDSC.4a.6.1)";
                break;
            case DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_CMP:
                if ((uint32_t) t->op > (uint32_t) DS__V1__ALPHA_CMP_OP__ALPHA_CMP_GTE)
                    malformed = "rete_loader: AlphaTest CMP op is no AlphaCmpOp "
                                "(RDSC.4a.6.1)";
                else if (!has_literal)
                    malformed = "rete_loader: AlphaTest CMP with no literal "
                                "(RDSC.4a.6.1)";
                break;
            case DS__V1__ALPHA_TEST_KIND__ALPHA_TEST_REGEX:
                /* RE2 compiles "", which matches everything. */
                if (t->pattern == NULL || t->pattern[0] == '\0')
                    malformed = "rete_loader: AlphaTest REGEX with no pattern "
                                "(RDSC.4a.6.1)";
                break;
            default:
                malformed = "rete_loader: AlphaTest kind is no AlphaTestKind "
                            "(RDSC.4a.6.1)";
                break;
            }
        }
        if (malformed != NULL) {
            r = DS_ERR_R(DS_ERR_DSC_SEMANTIC, malformed);
            goto done;
        }

        o->kind       = (ds_rete_alpha_test_kind_t) t->kind;
        o->slot_index = (uint8_t) t->slot_index;
        o->op         = (ds_rete_cmp_op_t) t->op;

        if (t->literal) {
            const Ds__V1__AlphaLiteral *lit = t->literal;
            switch (lit->value_case) {
            case DS__V1__ALPHA_LITERAL__VALUE_INT_VAL:
                o->literal = ds_rete_val_int(lit->int_val);
                break;
            case DS__V1__ALPHA_LITERAL__VALUE_FLOAT_VAL:
                /* [RDSC.9.10], whatever the test's kind. */
                if (rdsc_9_10_nan(lit->float_val)) {
                    r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                                 "rete_loader: AlphaLiteral.float_val is a NaN "
                                 "(RDSC.9.10)");
                    goto done;
                }
                o->literal = ds_rete_val_float(lit->float_val);
                break;
            case DS__V1__ALPHA_LITERAL__VALUE_STR_VAL: {
                if (re == NULL) break;
                const char *ip;
                r = ds_rete_intern_cstr(re->intern, lit->str_val, &ip);
                if (r.status != DS_OK) goto done;
                o->literal = ds_rete_val_str(ip, (uint32_t) strlen(lit->str_val));
                break;
            }
            case DS__V1__ALPHA_LITERAL__VALUE_BOOL_VAL:
                o->literal = ds_rete_val_bool(lit->bool_val != 0);
                break;
            case DS__V1__ALPHA_LITERAL__VALUE__NOT_SET:
            default:
                break;
            }
        }

        /* NULL for an empty pattern, which proto3 cannot tell from an absent one. */
        if (t->pattern[0]) {
            o->pattern = DS_STRDUP(t->pattern);
            if (!o->pattern) {
                r = DS_ERR_R(DS_ERR_OOM, "rete_loader: alfa pattern");
                goto done;
            }
        }
        test_count++;
    }

    out_atom->schema_name = schema_name; schema_name = NULL;
    out_atom->tests       = tests;       tests       = NULL;
    out_atom->test_count  = test_count;
    *out_tests = out_atom->tests;

done:
    DS_FREE(schema_name);
    if (tests) {
        for (uint32_t i = 0; i < test_count; i++)
            DS_FREE((char *) tests[i].pattern);
        DS_FREE(tests);
    }
    ds__v1__alpha_node__free_unpacked(msg, &ds_pb_allocator);
    return r;
}

ds_result_t ds_dsc_alfa_schema_name(const uint8_t *body, size_t len,
                                 uint32_t *out_node_id, char **out_name)
{
    *out_name = NULL;
    ds_result_t gate = rdsc_11_4_gate(&ds__v1__alpha_node__descriptor, body,
                                      len, ALFA_UNDECODABLE, ALFA_REPEATED,
                                      ALFA_BAD_STRING);
    if (gate.status != DS_OK) return gate;
    Ds__V1__AlphaNode *msg =
        ds__v1__alpha_node__unpack(&ds_pb_allocator, len, body);
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, ALFA_UNDECODABLE);
    *out_node_id = msg->node_id;
    *out_name = DS_STRDUP(msg->schema_name ? msg->schema_name : "");
    ds__v1__alpha_node__free_unpacked(msg, &ds_pb_allocator);
    if (!*out_name)
        return DS_ERR_R(DS_ERR_OOM, "rete_loader: alfa schema_name");
    return DS_OK_R;
}

ds_result_t ds_dsc_term_rule_name(const uint8_t *body, size_t len,
                                  char **out_name)
{
    *out_name = NULL;
    ds_result_t gate = rdsc_11_4_gate(&ds__v1__terminal_node__descriptor, body,
                                      len, TERM_UNDECODABLE, TERM_REPEATED,
                                      TERM_BAD_STRING);
    if (gate.status != DS_OK) return gate;
    Ds__V1__TerminalNode *msg =
        ds__v1__terminal_node__unpack(&ds_pb_allocator, len, body);
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, TERM_UNDECODABLE);
    *out_name = DS_STRDUP(msg->rule_name ? msg->rule_name : "");
    ds__v1__terminal_node__free_unpacked(msg, &ds_pb_allocator);
    if (!*out_name)
        return DS_ERR_R(DS_ERR_OOM, "rete_loader: term rule_name");
    return DS_OK_R;
}

/* ---- BetaNode atom decoder ------------------------------------------- */

static ds_result_t decode_beta(const uint8_t *data, size_t len,
                                ds_rete_engine_t *re,
                                ds_beta_atom_t *out_atom,
                                ds_rete_join_test_t **out_tests)
{
    ds_result_t gate = rdsc_11_4_gate(&ds__v1__beta_node__descriptor, data,
                                      len, BETA_UNDECODABLE, BETA_REPEATED,
                                      BETA_BAD_STRING);
    if (gate.status != DS_OK) return gate;
    Ds__V1__BetaNode *msg =
        ds__v1__beta_node__unpack(&ds_pb_allocator, len, data);
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, BETA_UNDECODABLE);

    ds_rete_join_test_t *jt = NULL;
    uint32_t             n_jt = 0;
    ds_result_t          r = DS_OK_R;

    out_atom->node_id        = msg->node_id;
    out_atom->right_alpha_id = msg->right_alpha_id;
    out_atom->left_parent_id = msg->left_parent_id;
    out_atom->is_negative    = (msg->is_negative != 0);

    if (msg->node_id == 0) {
        r = DS_ERR_R(DS_ERR_RETP_INVALID,
                     "rete_loader: BetaNode node_id 0 is reserved (RDSC.4a.3)");
        goto done;
    }

    if (msg->n_join_tests) {
        jt = DS_CALLOC(msg->n_join_tests, sizeof(*jt));
        if (!jt) {
            r = DS_ERR_R(DS_ERR_OOM, "rete_loader: beta join_tests alloc");
            goto done;
        }
        for (size_t i = 0; i < msg->n_join_tests; i++) {
            r = decode_expr_msg(msg->join_tests[i], re, 0, &jt[n_jt].expr);
            if (r.status != DS_OK) goto done;
            n_jt++;
        }
        out_atom->join_tests      = jt;
        out_atom->join_test_count = n_jt;
        *out_tests = jt;
        jt = NULL;
    }

done:
    if (jt) {
        for (uint32_t i = 0; i < n_jt; i++)
            ds_rete_expr_free_tree(jt[i].expr);
        DS_FREE(jt);
    }
    ds__v1__beta_node__free_unpacked(msg, &ds_pb_allocator);
    return r;
}

/* ---- TerminalNode atom decoder ------------------------------------------- */

static ds_result_t decode_action(const Ds__V1__Action *msg,
                                 ds_rete_engine_t *re,
                                 ds_rete_action_t *out)
{
    memset(out, 0, sizeof(*out));

    ds_rete_slot_assign_t *assigns   = NULL;
    uint32_t               n_assigns = 0;
    ds_result_t            r         = DS_OK_R;

    /* [IRET.10.6] */
    switch (msg->kind) {
    case DS__V1__ACTION_KIND__ACTION_CALL:
        if (!msg->expr)
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "rete_loader: ACTION_CALL with no expr (RDSC.11.3)");
        out->kind = DS_RETE_ACTION_CALL;
        break;
    case DS__V1__ACTION_KIND__ACTION_ASSERT:
        out->kind = DS_RETE_ACTION_ASSERT;
        break;
    case DS__V1__ACTION_KIND__ACTION_LOGICAL_ASSERT:
        out->kind = DS_RETE_ACTION_LOGICAL_ASSERT;
        break;
    case DS__V1__ACTION_KIND__ACTION_WITHDRAW:
        /* [RDSC.4a.9.1]: 0..254, with no marker. */
        if (msg->withdraw_pattern_index >= DS_RETE_VAR_RIGHT_FACT)
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "rete_loader: withdraw_pattern_index past 254 "
                            "(RDSC.4a.9.1)");
        out->kind = DS_RETE_ACTION_WITHDRAW;
        out->withdraw_pattern_index = (uint8_t) msg->withdraw_pattern_index;
        break;
    case DS__V1__ACTION_KIND__ACTION_WITHDRAW_BY_ID:
        if (!msg->withdraw_fact_id)
            return DS_ERR_R(DS_ERR_DSC_DECODE,
                            "rete_loader: ACTION_WITHDRAW_BY_ID without "
                            "withdraw_fact_id (IRET.10.7)");
        out->kind = DS_RETE_ACTION_WITHDRAW_BY_ID;
        break;
    default:
        return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                        "rete_loader: an action kind this engine does not "
                        "execute (IRET.10.6)");
    }

    /* WITHDRAW_BY_ID's expression is field 7; field 2 means nothing on that kind. */
    if (out->kind == DS_RETE_ACTION_WITHDRAW_BY_ID) {
        r = decode_expr_msg(msg->withdraw_fact_id, re, 0, &out->expr);
        if (r.status != DS_OK) goto done;
    } else if (msg->expr) {
        r = decode_expr_msg(msg->expr, re, 0, &out->expr);
        if (r.status != DS_OK) goto done;
    }

    /* [LDTL.4.1] */
    if (msg->ttl_override) {
        r = decode_expr_msg(msg->ttl_override, re, 0, &out->ttl_override);
        if (r.status != DS_OK) goto done;
    }

    if (msg->n_assigns) {
        assigns = DS_CALLOC(msg->n_assigns, sizeof(*assigns));
        if (!assigns) {
            r = DS_ERR_R(DS_ERR_OOM, "rete_loader: assigns alloc");
            goto done;
        }
        for (size_t i = 0; i < msg->n_assigns; i++) {
            const Ds__V1__SlotAssign *sa = msg->assigns[i];
            if (!sa->expr) {
                r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                             "rete_loader: SlotAssign with no expr (RDSC.11.3)");
                goto done;
            }
            if (sa->slot_index >= DS_RETE_VAR_WHOLE_FACT) {
                r = DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                             "rete_loader: SlotAssign slot_index past 254 "
                             "(RDSC.4a.9.1)");
                goto done;
            }
            assigns[n_assigns].slot_index = (uint8_t) sa->slot_index;
            r = decode_expr_msg(sa->expr, re, 0, &assigns[n_assigns].expr);
            if (r.status != DS_OK) goto done;
            n_assigns++;
        }
    }

    /* The one check that needs the registered schemas, so the walk skips it. */
    if (msg->schema_name[0] && re != NULL) {
        const ds_rete_schema_t *s = ds_rete_schema_by_name(re, msg->schema_name);
        if (!s) {
            ds_text_t d = ds_rete_engine_detail(re);
            ds_text_str(&d, "rete_loader: action schema '");
            ds_text_str(&d, msg->schema_name);
            ds_text_str(&d, "' not registered in the Rete engine");
            r = DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN, ds_rete_engine_detail_text(&d,
                     "rete_loader: an action schema is not registered in the "
                     "Rete engine"));
            goto done;
        }
        out->schema_id = s->id;
    }

    out->assigns      = assigns;  assigns = NULL;
    out->assign_count = n_assigns;

done:
    if (assigns) {
        for (uint32_t i = 0; i < n_assigns; i++)
            ds_rete_expr_free_tree(assigns[i].expr);
        DS_FREE(assigns);
    }
    if (r.status != DS_OK) {
        ds_rete_expr_free_tree(out->expr);          out->expr = NULL;
        ds_rete_expr_free_tree(out->ttl_override);  out->ttl_override = NULL;
    }
    return r;
}

static ds_result_t decode_term(const uint8_t *data, size_t len,
                                ds_rete_engine_t *re,
                                ds_term_atom_t *out_atom,
                                ds_rete_action_t **out_actions)
{
    ds_result_t gate = rdsc_11_4_gate(&ds__v1__terminal_node__descriptor, data,
                                      len, TERM_UNDECODABLE, TERM_REPEATED,
                                      TERM_BAD_STRING);
    if (gate.status != DS_OK) return gate;
    Ds__V1__TerminalNode *msg =
        ds__v1__terminal_node__unpack(&ds_pb_allocator, len, data);
    if (!msg)
        return DS_ERR_R(DS_ERR_DSC_DECODE, TERM_UNDECODABLE);

    char             *rule_name  = NULL;
    ds_rete_action_t *actions    = NULL;
    uint32_t          n_actions  = 0;
    ds_rete_expr_t   *fire_guard = NULL;
    ds_result_t       r          = DS_OK_R;

    out_atom->node_id         = msg->node_id;
    out_atom->parent_beta_id  = msg->parent_beta_id;
    out_atom->bind_count      = msg->bind_count;

    if (msg->node_id == 0) {
        r = DS_ERR_R(DS_ERR_RETP_INVALID,
                     "rete_loader: TerminalNode node_id 0 is reserved (RDSC.4a.3)");
        goto done;
    }

    rule_name = DS_STRDUP(msg->rule_name);
    if (!rule_name) {
        r = DS_ERR_R(DS_ERR_OOM, "rete_loader: term rule_name");
        goto done;
    }

    if (msg->fire_guard) {
        r = decode_expr_msg(msg->fire_guard, re, 0, &fire_guard);
        if (r.status != DS_OK) goto done;
    }

    if (msg->n_actions) {
        actions = DS_CALLOC(msg->n_actions, sizeof(*actions));
        if (!actions) {
            r = DS_ERR_R(DS_ERR_OOM, "rete_loader: actions alloc");
            goto done;
        }
        for (size_t i = 0; i < msg->n_actions; i++) {
            r = decode_action(msg->actions[i], re, &actions[n_actions]);
            if (r.status != DS_OK) goto done;
            n_actions++;
        }
    }

    out_atom->rule_name    = rule_name;  rule_name  = NULL;
    out_atom->actions      = actions;    actions    = NULL;
    out_atom->action_count = n_actions;
    out_atom->fire_guard   = fire_guard; fire_guard = NULL;
    *out_actions = out_atom->actions;

done:
    DS_FREE(rule_name);
    if (actions) {
        for (uint32_t i = 0; i < n_actions; i++)
            ds_rete_action_free(&actions[i]);
        DS_FREE(actions);
    }
    if (fire_guard) ds_rete_expr_free_tree(fire_guard);
    ds__v1__terminal_node__free_unpacked(msg, &ds_pb_allocator);
    return r;
}

/* ---- What a decoded atom still owns ------------------------------- */

/* Each frees what its atom still owns, on any path: ds_rete_load_network NULLs
   every expression it takes into the engine. */
static void alfa_atom_dispose(ds_alfa_atom_t *a)
{
    DS_FREE((char *) a->schema_name);
    if (a->tests) {
        for (uint32_t t = 0; t < a->test_count; t++)
            DS_FREE((char *) a->tests[t].pattern);
        DS_FREE(a->tests);
    }
}

static void beta_atom_dispose(ds_beta_atom_t *b)
{
    if (b->join_tests) {
        for (uint32_t j = 0; j < b->join_test_count; j++)
            ds_rete_expr_free_tree(b->join_tests[j].expr);
        DS_FREE(b->join_tests);
    }
}

static void term_atom_dispose(ds_term_atom_t *t)
{
    DS_FREE((char *) t->rule_name);
    if (t->actions) {
        /* terminal_add_action deep-copies each action's assigns array. */
        for (uint32_t a = 0; a < t->action_count; a++)
            ds_rete_action_free(&t->actions[a]);
        DS_FREE(t->actions);
    }
    ds_rete_expr_free_tree(t->fire_guard);
}

/* ---- The walk's check --------------------------------------------- */

ds_result_t ds_dsc_rete_body_decodes(dsc_rete_kind_t kind,
                                  const uint8_t *body, size_t len)
{
    ds_result_t r;
    switch (kind) {
    case DSC_RETE_ALPHA: {
        ds_alfa_atom_t        a = {0};
        ds_retp_alpha_test_t *tests = NULL;
        r = decode_alfa(body, len, NULL, &a, &tests);
        alfa_atom_dispose(&a);
        return r;
    }
    case DSC_RETE_BETA: {
        ds_beta_atom_t       b = {0};
        ds_rete_join_test_t *tests = NULL;
        r = decode_beta(body, len, NULL, &b, &tests);
        beta_atom_dispose(&b);
        return r;
    }
    case DSC_RETE_TERMINAL: {
        ds_term_atom_t    t = {0};
        ds_rete_action_t *actions = NULL;
        r = decode_term(body, len, NULL, &t, &actions);
        term_atom_dispose(&t);
        return r;
    }
    }
    return DS_ERR_R(DS_ERR_INVAL, "rete_loader: not a network atom kind");
}

/* ---- [RDSC.9.5]'s offset and reason ------------------------------- */

/* The first wire error in a body's top-level fields. */
typedef enum {
    RDSC_9_5_NONE,
    RDSC_9_5_TRUNCATED,        /* the body, or a declared length, ends early */
    RDSC_9_5_VARINT_OVERLONG,  /* > 10 bytes, or a 10th byte past bit 64 */
    RDSC_9_5_BAD_WIRE_TYPE,    /* 3, 4, 6 or 7: none DS writes */
    RDSC_9_5_FIELD_OVERFLOW,   /* a field number past 2^32 - 1 */
    RDSC_9_5_LENGTH_OVERFLOW,  /* a length past 2^31 - 1 */
} rdsc_9_5_wire_t;

static rdsc_9_5_wire_t rdsc_9_5_varint(const uint8_t *p, size_t len,
                                       size_t *pos, uint64_t *out)
{
    uint64_t acc = 0;
    for (unsigned group = 0; ; group++) {
        if (group >= 10) return RDSC_9_5_VARINT_OVERLONG;
        if (*pos >= len) return RDSC_9_5_TRUNCATED;
        const uint8_t  b   = p[(*pos)++];
        const uint64_t low = b & 0x7Fu;
        /* 9 * 7 = 63: the tenth group carries one bit at most. */
        if (group == 9 && low > 1u) return RDSC_9_5_VARINT_OVERLONG;
        acc |= low << (group * 7u);
        if ((b & 0x80u) == 0) { *out = acc; return RDSC_9_5_NONE; }
    }
}

/* `*wire_type` is the type a BAD_WIRE_TYPE names. */
static rdsc_9_5_wire_t rdsc_9_5_walk(const uint8_t *p, size_t len,
                                     unsigned *wire_type)
{
    size_t pos = 0;
    while (pos < len) {
        uint64_t tag = 0;
        rdsc_9_5_wire_t e = rdsc_9_5_varint(p, len, &pos, &tag);
        if (e != RDSC_9_5_NONE) return e;
        const unsigned wt = (unsigned) (tag & 7u);
        if (wt != 0 && wt != 1 && wt != 2 && wt != 5) {
            *wire_type = wt;
            return RDSC_9_5_BAD_WIRE_TYPE;
        }
        if ((tag >> 3) > 0xFFFFFFFFu) return RDSC_9_5_FIELD_OVERFLOW;
        uint64_t n = 0;
        switch (wt) {
        case 0:
            e = rdsc_9_5_varint(p, len, &pos, &n);
            if (e != RDSC_9_5_NONE) return e;
            break;
        case 1:
            if (len - pos < 8) return RDSC_9_5_TRUNCATED;
            pos += 8;
            break;
        case 5:
            if (len - pos < 4) return RDSC_9_5_TRUNCATED;
            pos += 4;
            break;
        default: /* 2 */
            e = rdsc_9_5_varint(p, len, &pos, &n);
            if (e != RDSC_9_5_NONE) return e;
            if (n > 0x7FFFFFFFu) return RDSC_9_5_LENGTH_OVERFLOW;
            if (n > len - pos) return RDSC_9_5_TRUNCATED;
            pos += (size_t) n;
            break;
        }
    }
    return RDSC_9_5_NONE;
}

ds_result_t ds_dsc_decode_at_offset(struct ds_rete_engine *re, ds_result_t r,
                                 size_t offset,
                                 const uint8_t *body, size_t len)
{
    if (r.status != DS_ERR_DSC_DECODE) return r;
    /* Copied first: a decoder may have written its detail into the buffer this
       rewrites. */
    char decoder_detail[192];
    decoder_detail[0] = '\0';
    if (r.detail != NULL) {
        strncpy(decoder_detail, r.detail, sizeof decoder_detail - 1);
        decoder_detail[sizeof decoder_detail - 1] = '\0';
    }
    ds_text_t d = ds_rete_engine_detail(re);
    ds_text_str(&d, decoder_detail[0] ? decoder_detail
                                      : "dsc: an atom body failed to decode");
    ds_text_str(&d, " at offset ");
    ds_text_u64(&d, (uint64_t) offset);
    /* protobuf-c's `unpack` gives no reason, so the body's top-level fields are
       read again. These words match `ds.dsc.wire_reason`: one vector reads both
       runtimes' text. */
    unsigned wt = 0;
    switch (body != NULL ? rdsc_9_5_walk(body, len, &wt) : RDSC_9_5_NONE) {
    case RDSC_9_5_NONE:
        break;
    case RDSC_9_5_TRUNCATED:
        ds_text_str(&d, ": the body ends mid-value");
        break;
    case RDSC_9_5_VARINT_OVERLONG:
        ds_text_str(&d, ": a varint is longer than ten bytes or carries bits "
                        "above 64");
        break;
    case RDSC_9_5_BAD_WIRE_TYPE:
        ds_text_str(&d, ": wire type ");
        ds_text_u64(&d, (uint64_t) wt);
        ds_text_str(&d, " is not one DS writes");
        break;
    case RDSC_9_5_FIELD_OVERFLOW:
        ds_text_str(&d, ": a field number does not fit");
        break;
    case RDSC_9_5_LENGTH_OVERFLOW:
        ds_text_str(&d, ": a declared length does not fit");
        break;
    }
    ds_text_str(&d, " (RDSC.9.5)");
    r.detail = ds_rete_engine_detail_text(&d, r.detail);
    return r;
}

/* ---- Public entry point ------------------------------------------ */

ds_result_t ds_dsc_apply_rete_network(
    struct ds_rete_engine      *re,
    const dsc_rete_atom_t      *alfas,   uint32_t n_alfas,
    const dsc_rete_atom_t      *betas,   uint32_t n_betas,
    const dsc_rete_atom_t      *terms,   uint32_t n_terms)
{
    if (!re) return DS_ERR_R(DS_ERR_INVAL, "rete_loader: no rete_engine");

    ds_result_t r = DS_OK_R;

    ds_alfa_atom_t       *alfa_atoms = NULL;
    ds_retp_alpha_test_t **alfa_test_ptrs = NULL;
    ds_beta_atom_t       *beta_atoms = NULL;
    ds_rete_join_test_t  **beta_test_ptrs = NULL;
    ds_term_atom_t       *term_atoms = NULL;
    ds_rete_action_t     **term_action_ptrs = NULL;

    if (n_alfas) {
        alfa_atoms     = DS_CALLOC(n_alfas, sizeof(*alfa_atoms));
        alfa_test_ptrs = DS_CALLOC(n_alfas, sizeof(*alfa_test_ptrs));
        if (!alfa_atoms || !alfa_test_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "rete_loader: alfa arrays"); goto cleanup; }
    }
    if (n_betas) {
        beta_atoms     = DS_CALLOC(n_betas, sizeof(*beta_atoms));
        beta_test_ptrs = DS_CALLOC(n_betas, sizeof(*beta_test_ptrs));
        if (!beta_atoms || !beta_test_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "rete_loader: beta arrays"); goto cleanup; }
    }
    if (n_terms) {
        term_atoms       = DS_CALLOC(n_terms, sizeof(*term_atoms));
        term_action_ptrs = DS_CALLOC(n_terms, sizeof(*term_action_ptrs));
        if (!term_atoms || !term_action_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "rete_loader: term arrays"); goto cleanup; }
    }

    for (uint32_t i = 0; i < n_alfas; i++) {
        r = decode_alfa(alfas[i].body, alfas[i].len, re,
                        &alfa_atoms[i], &alfa_test_ptrs[i]);
        if (r.status != DS_OK) {
            r = ds_dsc_decode_at_offset(re, r, alfas[i].offset,
                                        alfas[i].body, alfas[i].len);
            goto cleanup;
        }
    }
    for (uint32_t i = 0; i < n_betas; i++) {
        r = decode_beta(betas[i].body, betas[i].len, re,
                        &beta_atoms[i], &beta_test_ptrs[i]);
        if (r.status != DS_OK) {
            r = ds_dsc_decode_at_offset(re, r, betas[i].offset,
                                        betas[i].body, betas[i].len);
            goto cleanup;
        }
    }
    for (uint32_t i = 0; i < n_terms; i++) {
        r = decode_term(terms[i].body, terms[i].len, re,
                        &term_atoms[i], &term_action_ptrs[i]);
        if (r.status != DS_OK) {
            r = ds_dsc_decode_at_offset(re, r, terms[i].offset,
                                        terms[i].body, terms[i].len);
            goto cleanup;
        }
    }

    ds_rete_network_t network = {
        .alfas      = alfa_atoms, .alfa_count = n_alfas,
        .betas      = beta_atoms, .beta_count = n_betas,
        .terms      = term_atoms, .term_count = n_terms,
    };
    r = ds_rete_load_network(re, &network);

cleanup:;
    /* An array is NULL here when its allocation, or an earlier one, failed. */
    for (uint32_t i = 0; alfa_atoms != NULL && i < n_alfas; i++)
        alfa_atom_dispose(&alfa_atoms[i]);
    for (uint32_t i = 0; beta_atoms != NULL && i < n_betas; i++)
        beta_atom_dispose(&beta_atoms[i]);
    for (uint32_t i = 0; term_atoms != NULL && i < n_terms; i++)
        term_atom_dispose(&term_atoms[i]);

    DS_FREE(alfa_atoms); DS_FREE(alfa_test_ptrs);
    DS_FREE(beta_atoms); DS_FREE(beta_test_ptrs);
    DS_FREE(term_atoms); DS_FREE(term_action_ptrs);
    return r;
}

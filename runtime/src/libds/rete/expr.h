/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/expr.h — expression AST (IRET.9.1).
 *
 * Nodes are read-only after load. String literals are interned pointers.
 */
#ifndef LIBDS2_INTERNAL_RETE_EXPR_H
#define LIBDS2_INTERNAL_RETE_EXPR_H

#include <stdbool.h>
#include <stdint.h>

#include "libds.h"
#include "rete/val.h"

/* ---- Expression kind (IRET.9.1) ----------------------------------- */

typedef enum {
    DS_RETE_EXPR_LIT_INT,
    DS_RETE_EXPR_LIT_FLOAT,
    DS_RETE_EXPR_LIT_STR,
    DS_RETE_EXPR_LIT_BOOL,
    DS_RETE_EXPR_LIT_NULL,
    DS_RETE_EXPR_VAR,
    DS_RETE_EXPR_BINOP,
    DS_RETE_EXPR_UNOP,
    DS_RETE_EXPR_CALL,
    DS_RETE_EXPR_INTERP,     /* RLOW.6.4 */
    DS_RETE_EXPR_NOW,
    DS_RETE_EXPR_JSON_PATH,
    DS_RETE_EXPR_IF,
    DS_RETE_EXPR_BIND,
    DS_RETE_EXPR_BIND_REF,
    /* [LNUL.8.9] `left ?? right`: `left` evaluated once, `right` only if it is
     * null. */
    DS_RETE_EXPR_COALESCE,
    /* [LNUL.4.9] `x is [not] <subject>`: the total tag test, never null and
     * never a fault. */
    DS_RETE_EXPR_IS_TEST,
    /* [LTIM.2.8.6] the entry stamp of the fact at a pattern index: the monotonic
     * sample when it entered working memory, as a Duration. Engine state, not a
     * slot. */
    DS_RETE_EXPR_ENTRY_STAMP,
} ds_rete_expr_kind_t;

/* ---- `is` subjects ([LNUL.4.9], proto/rete_expr.proto#IsSubject) --- */

/* Values match the wire enum. */
typedef enum {
    DS_RETE_IS_UNSPECIFIED = 0,  /* refused at load */
    DS_RETE_IS_NULL        = 1,
    DS_RETE_IS_TRUE        = 2,
    DS_RETE_IS_FALSE       = 3,
    DS_RETE_IS_INF         = 4,
    DS_RETE_IS_NEG_INF     = 5,
    DS_RETE_IS_NAN         = 6,
    DS_RETE_IS_INT         = 7,
    DS_RETE_IS_FLOAT       = 8,
    DS_RETE_IS_BOOL        = 9,
    DS_RETE_IS_STRING      = 10,
    DS_RETE_IS_BYTES       = 11,
    DS_RETE_IS_JSON        = 12,
} ds_rete_is_subject_t;

/* ---- Binary and unary operators (IRET.9.7) ------------------------ */

typedef enum {
    /* Arithmetic (Int×Int→Int, Float×Float→Float, Int×Float→Float) */
    DS_RETE_BINOP_ADD,
    DS_RETE_BINOP_SUB,
    DS_RETE_BINOP_MUL,
    DS_RETE_BINOP_DIV,
    /* Integer-only */
    DS_RETE_BINOP_IDIV,  /* // */
    DS_RETE_BINOP_MOD,   /* %  */
    /* Comparison */
    DS_RETE_BINOP_EQ,
    DS_RETE_BINOP_NE,
    DS_RETE_BINOP_LT,
    DS_RETE_BINOP_GT,
    DS_RETE_BINOP_LE,
    DS_RETE_BINOP_GE,
    /* Logical (Bool×Bool→Bool, short-circuit) */
    DS_RETE_BINOP_AND,
    DS_RETE_BINOP_OR,
    /* Bitwise (Int×Int→Int) */
    DS_RETE_BINOP_BAND,
    DS_RETE_BINOP_BOR,
    DS_RETE_BINOP_BXOR,
    DS_RETE_BINOP_SHL,
    DS_RETE_BINOP_SHR,
} ds_rete_binop_t;

typedef enum {
    DS_RETE_UNOP_NOT,   /* logical not: Bool→Bool */
    DS_RETE_UNOP_BNOT,  /* bit-not:     Int→Int   */
    DS_RETE_UNOP_NEG,   /* negate:      Int→Int, Float→Float */
} ds_rete_unop_t;

/* ---- VAR markers (IRET.9.3, [RDSC.4a.9.1]) ------------------------ */

/*
 * A slot or pattern index is a byte, 0..254, and 255 is a marker where the
 * field has one ([RDSC.4a.9.1]):
 *
 * pattern_index == DS_RETE_VAR_RIGHT_FACT: read from ctx->right_fact.
 * slot_index == DS_RETE_VAR_WHOLE_FACT: the fact itself, as a reference.
 */
#define DS_RETE_VAR_RIGHT_FACT ((uint8_t)255)
#define DS_RETE_VAR_WHOLE_FACT ((uint8_t)255)

/* ---- Interpolation (RLOW.6.4, proto/rete_expr.proto#InterpExpr) ---- */

/* The spec of one value, resolved by the compiler ([LGRA.2.9.6.5]). Values match
   the wire enums. */
typedef enum {
    DS_RETE_FALIGN_DEFAULT = 0,   /* a number right, a String or Bool left */
    DS_RETE_FALIGN_LEFT    = 1,
    DS_RETE_FALIGN_RIGHT   = 2,
} ds_rete_falign_t;

typedef enum {
    DS_RETE_FTYPE_CANONICAL = 0,  /* no type: the value's canonical text */
    DS_RETE_FTYPE_D         = 1,
    DS_RETE_FTYPE_F         = 2,
    DS_RETE_FTYPE_S         = 3,
    DS_RETE_FTYPE_X_LOWER   = 4,
    DS_RETE_FTYPE_X_UPPER   = 5,
    DS_RETE_FTYPE_B         = 6,
} ds_rete_ftype_t;

/* [LGRA.2.9.6.4]'s directives; 0 is refused at load. */
typedef enum {
    DS_RETE_TFIELD_YEAR        = 1,  /* %Y */
    DS_RETE_TFIELD_MONTH       = 2,  /* %m */
    DS_RETE_TFIELD_DAY         = 3,  /* %d */
    DS_RETE_TFIELD_HOUR        = 4,  /* %H */
    DS_RETE_TFIELD_MINUTE      = 5,  /* %M */
    DS_RETE_TFIELD_SECOND      = 6,  /* %S */
    DS_RETE_TFIELD_MICROSECOND = 7,  /* %f */
    DS_RETE_TFIELD_UTC_OFFSET  = 8,  /* %z */
} ds_rete_tfield_t;

typedef struct {
    const char       *text;     /* interned; NULL for a field */
    uint32_t          text_len;
    ds_rete_tfield_t  field;    /* meaningful when text == NULL */
} ds_rete_titem_t;

typedef enum {
    DS_RETE_FPRIM_TEXT,
    DS_RETE_FPRIM_VALUE,
    DS_RETE_FPRIM_TIME,
} ds_rete_fprim_kind_t;

typedef struct {
    ds_rete_fprim_kind_t  kind;
    /* TEXT */
    const char           *text;
    uint32_t              text_len;
    /* VALUE and TIME */
    struct ds_rete_expr  *value;
    /* VALUE */
    ds_rete_falign_t      align;
    ds_rete_ftype_t       type;
    bool                  plus;
    bool                  zero;
    bool                  has_precision;
    uint32_t              width;       /* in code points; 0 = no minimum */
    uint32_t              precision;   /* meaningful when has_precision */
    /* TIME */
    ds_rete_titem_t      *items;
    uint32_t              item_count;
} ds_rete_fprim_t;

/* ---- Expression node (IRET.9.1) ----------------------------------- */

typedef struct ds_rete_expr {
    ds_rete_expr_kind_t kind;
    union {
        int64_t    lit_int;
        double     lit_float;
        const char *lit_str;   /* interned */
        bool       lit_bool;

        /* IRET.9.3 */
        struct {
            uint8_t pattern_index; /* DS_RETE_VAR_RIGHT_FACT = right fact */
            uint8_t slot_index;    /* DS_RETE_VAR_WHOLE_FACT = the fact */
        } var;

        struct {
            ds_rete_binop_t       op;
            struct ds_rete_expr  *left;
            struct ds_rete_expr  *right;
        } binop;

        struct {
            ds_rete_unop_t        op;
            struct ds_rete_expr  *operand;
        } unop;

        /* `op` is a ds_builtin_fn_t. */
        struct {
            uint32_t              op;
            struct ds_rete_expr **args;
            uint32_t              arg_count;
        } call;

        /* Every spec was resolved at compile time. */
        struct {
            ds_rete_fprim_t      *prims;
            uint32_t              prim_count;
        } interp;

        struct {
            struct ds_rete_expr  *val;
            struct ds_rete_expr  *path; /* evaluates to String */
        } json_path;

        struct {
            struct ds_rete_expr  *cond;
            struct ds_rete_expr  *then_;
            struct ds_rete_expr  *else_;
        } if_;

        /* IRET.9.4 */
        struct {
            uint32_t              bind_index;
            struct ds_rete_expr  *expr;
        } bind;

        struct {
            uint32_t              bind_index;
        } bind_ref;

        struct {
            struct ds_rete_expr  *left;
            struct ds_rete_expr  *right;
        } coalesce;

        struct {
            struct ds_rete_expr  *operand;
            ds_rete_is_subject_t  subject;
            bool                  negated;
        } is_test;

        /* pattern_index as VAR's ([RDSC.4a.9.1]). */
        struct {
            uint8_t               pattern_index;
        } entry_stamp;
    };
    /* This value derives from a `Json` projection, which splits an ill-typed
     * operation between TypeError and EngineError. A value carries no
     * provenance, so the compiler lowers it (`Expr.json_tainted`). */
    bool json_tainted;
} ds_rete_expr_t;

/* A zeroed node. */
ds_rete_expr_t *ds_rete_expr_alloc(ds_rete_expr_kind_t kind);

/* Interned strings are not freed. */
void ds_rete_expr_free_tree(ds_rete_expr_t *expr);

#endif /* LIBDS2_INTERNAL_RETE_EXPR_H */

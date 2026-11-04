// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// The tree-sitter grammar for DS, written from [LGRA]'s productions.
//
// THE PRODUCTIONS ARE THE SPEC'S, each citing its clause. Where [LGRA] says a
// form parses and the validator refuses it (a kwarg the action does not take,
// an accuracy phrase, a tuple `let`), this grammar parses it too: a parse is
// the shape of a program, and the compiler's diagnostics are for the rest
// ([LGRA.10.3.2]). A deferred form is parsed too: the compiler parses `unit
// fx_pair` and then refuses it ([LUNI.13.11]).
//
// LAYOUT IS THE LEXER'S ([LLEX.6]): src/scanner.c emits NEWLINE, INDENT and
// DEDENT, and suspends them inside brackets ([LLEX.7.5.5]), where a newline is
// whitespace. A block opens on `:` (or `->`) with INDENT, as tree-sitter-python
// opens one, and closes with DEDENT.
//
// NO WORD LIST IS TYPED HERE. Every reserved word this grammar spells is a
// terminal of a production; the generator holds each to [LLEX.9.6] and
// writes queries/highlights.scm from that table and [LEXP.17.2], and its
// test fails on drift. A word
// is a keyword only where a production expects it: tree-sitter reads it as an
// identifier everywhere else, so a slot read (`r.count`) or an alias (`alias
// in`) is never a keyword ([LLEX.9.5]).

/* eslint-disable no-undef */

const PREC = {
    // [LGRA.9.2.1], lowest first.
    or: 1,
    and: 2,
    not: 3,
    compare: 4,
    coalesce: 5,
    match: 6,
    interval_rel: 7,
    interval: 8,
    bit_or: 9,
    bit_xor: 10,
    bit_and: 11,
    shift: 12,
    add: 13,
    mul: 14,
    pow: 15,
    unary: 16,
    postfix: 17,
};

/** One or more `rule`, separated by commas. */
const commaSep1 = (rule) => seq(rule, repeat(seq(",", rule)));

/** [LLEX.11.1]: DEC_LIT, one `_` between two digits. */
const DEC = /[0-9](_?[0-9])*/.source;
/** [LLEX.11.2]: EXPONENT. */
const EXP = /[eE][+-]?[0-9](_?[0-9])*/.source;
/** [LLEX.12.2]: the unit glyphs, with [LLEX.12.2.1]'s look-alikes the compiler folds to them. */
const GLYPHS = "°′″ΩµÅμΩʹʺ";
const UNIT_CONT = `A-Za-z0-9_${GLYPHS}ₙ`;

module.exports = grammar({
    name: "ds",

    externals: ($) => [$._newline, $._indent, $._dedent],

    // [LLEX.3]: spaces; [LGRA.2.2.2]: LF or CRLF, which src/scanner.c turns
    // into NEWLINE where a statement ends and leaves as whitespace inside
    // brackets.
    extras: ($) => [$.comment, /[ \t\f\r\n]/],

    word: ($) => $.identifier,

    conflicts: ($) => [
        // [LGRA.8.1]: after `where ( NAME )` one token decides between a
        // parenthesised expression and a capture binding: `=` selects it.
        [$._primary_expression, $.capture_binding],
    ],

    rules: {
        // ── [LGRA.3.1] file structure ───────────────────────────────────────
        // Order (a `use` first, imports before declarations) is the
        // validator's ([LGRA.3.2], [LIMP.2.3.2]), not the parser's.
        source_file: ($) => repeat($._declaration),

        _declaration: ($) => choice(
            $.use_declaration,
            $.import_declaration,
            $.const_declaration,
            $.schema_declaration,
            $.rule_declaration,
            $.series_declaration,
            $.service_declaration,
            $.unit_declaration,
            $.opaque_declaration,
            $.test_declaration,
            $.initial_block,
        ),

        // [LGRA.3.1]: use_decl.
        use_declaration: ($) => seq(
            "use",
            field("dialect", $.identifier),
            choice($._newline, seq(":", $._indent, repeat1($.setting), $._dedent)),
        ),

        // [LGRA.3.1]: setting_line.
        setting: ($) => seq(field("name", $.identifier), ":", field("value", $.boolean), $._newline),

        // [LIMP.2.1.1]: the two import forms.
        import_declaration: ($) => seq(
            choice(
                seq("import", field("path", $.dotted_name), optional(seq("as", field("alias", $.identifier)))),
                seq(
                    "from", field("path", $.dotted_name), "import",
                    choice(
                        seq(commaSep1($.import_item), optional(",")),
                        seq("(", commaSep1($.import_item), optional(","), ")"),
                    ),
                ),
            ),
            $._newline,
        ),

        import_item: ($) => seq(field("name", $.identifier), optional(seq("as", field("alias", $.identifier)))),

        dotted_name: ($) => seq($.identifier, repeat(seq(".", $.identifier))),

        // ── [LGRA.4.1] constants ────────────────────────────────────────────
        const_declaration: ($) => seq(
            "const",
            field("name", $.identifier),
            optional(seq(":", field("type", $.type), optional("?"))),
            "=",
            field("value", $._expression),
            $._newline,
        ),

        // ── [LGRA.5.1] schemas ──────────────────────────────────────────────
        schema_declaration: ($) => seq(
            "schema",
            field("name", $.identifier),
            optional($.scope),
            ":",
            $._indent,
            optional($.docstring),
            repeat1($.field_declaration),
            $._dedent,
        ),

        // [LGRA.5.1]: schema_lifecycle.
        scope: ($) => seq(
            "scope",
            choice(
                "explicit",
                "activation",
                seq("logical", optional("ambient")),
                seq("ttl", $._time_expr, optional("ambient")),
            ),
        ),

        // [LGRA.5.1]: field_decl.
        field_declaration: ($) => seq(
            field("name", $.identifier),
            ":",
            field("type", $.type),
            optional("?"),
            optional(seq("capacity", $.integer)),
            repeat(choice("retained", "key", "mutable")),
            optional(seq("tolerance", $._number)),
            optional(field("doc", $.string)),
            $._newline,
        ),

        docstring: ($) => seq($.string, $._newline),

        // [LGRA.2.5.1]: TYPE_SYM, a NAME or a symbol spelled with a unit
        // glyph ([LGRA.2.5.2]).
        type: ($) => choice($.identifier, $.unit_symbol),

        // [LGRA.2.8.1]: time_expr.
        _time_expr: ($) => choice($.unit_literal, $.identifier),

        // ── [LGRA.6.1] rules ────────────────────────────────────────────────
        rule_declaration: ($) => seq(
            "rule",
            field("name", $.identifier),
            repeat($._rule_modifier),
            ":",
            $._indent,
            optional($.docstring),
            repeat1(choice($.pattern, $.negated_pattern)),
            $._dedent,
            // [LGRA.6.2]: `->` at column 0, then the RHS block.
            "->",
            $._indent,
            repeat1($._statement),
            $._dedent,
        ),

        _rule_modifier: ($) => choice($.cooldown, $.rate_key),

        // [LGRA.6.1]: rate_mod.
        cooldown: ($) => seq("cooldown", $._time_expr),

        // [LGRA.6.1]: rate_key.
        rate_key: ($) => seq("by", ":", choice(commaSep1($.key_path), "none")),

        key_path: ($) => seq($.identifier, ".", $.identifier),

        // [LGRA.6.1]: an action body is actions and `after` clauses, after
        // the lets ([LGRA.6.7.1]); their order is the validator's.
        _statement: ($) => choice($.let_declaration, $._action, $.after_clause),

        // [LGRA.6.1], [LGRA.6.7.4]: let, with its hanging-indent block.
        let_declaration: ($) => seq(
            "let",
            $.let_binding,
            optional(seq($._indent, repeat1($.let_binding), $._dedent)),
        ),

        // [LGRA.6.1]: let_binding; the tuple form parses and is refused
        // ([LREG.4.1]).
        let_binding: ($) => seq(
            choice(
                seq(field("name", $.identifier), optional(seq(":", field("type", $.type), optional("?")))),
                seq("(", commaSep1(field("name", $.identifier)), ")"),
            ),
            "=",
            field("value", $._expression),
            $._newline,
        ),

        // [LGRA.6.1]: after_clause, a bare UNIT_LIT ([LGRA.2.8.2]).
        after_clause: ($) => seq(
            "after",
            field("delay", $.unit_literal),
            optional(seq("as", field("correlation", $._expression))),
            ":",
            $._body,
        ),

        _body: ($) => seq($._indent, repeat1($._statement), $._dedent),

        // ── [LGRA.8.1] patterns ─────────────────────────────────────────────
        pattern: ($) => seq(
            choice(
                seq(optional("latest"), $._pattern_body, repeat($.then_step)),
                // the line-leading `then` layout ([LGRA.8.5.10])
                repeat1($.then_step),
            ),
            $._newline,
        ),

        negated_pattern: ($) => seq(
            "no",
            choice($._pattern_body, seq("(", $._pattern_body, ")")),
            $._newline,
        ),

        _pattern_body: ($) => seq(
            field("type", $.type_ref),
            optional(field("binding", $.identifier)),
            optional($.within_clause),
            optional($.where_clause),
        ),

        then_step: ($) => seq(
            "then",
            optional("latest"),
            field("type", $.type_ref),
            optional(field("binding", $.identifier)),
            $.within_clause,
            optional($.where_clause),
        ),

        // [LGRA.8.1]: a schema, bare or library-qualified ([LGRA.22.4]).
        type_ref: ($) => seq($.identifier, repeat(seq(".", $.identifier))),

        within_clause: ($) => seq("within", $._time_expr),

        where_clause: ($) => seq("where", choice($._expression, $.capture_binding)),

        // [LGRA.8.1]: deliberately permissive about its right-hand side.
        capture_binding: ($) => prec.right(seq(
            "(", commaSep1($.identifier), ")", "=", $._expression,
        )),

        // ── [LGRA.10.1] actions ─────────────────────────────────────────────
        _action: ($) => choice(
            $.call_action,
            $.log_action,
            $.emit_action,
            $.publish_action,
            $.cache_action,
            $.cache_delete_action,
            $.withdraw_action,
        ),

        // [LGRA.10.1]: log_level is case-insensitive ([LGRA.10.1.1]), so it
        // is a NAME here, checked by the compiler.
        log_action: ($) => seq(
            "log",
            field("level", $.identifier),
            field("message", $.string),
            repeat($._action_arg),
            $._newline,
        ),

        emit_action: ($) => seq("emit", field("type", $.type_ref), repeat($._action_arg), $._newline, optional($.action_block)),

        publish_action: ($) => seq("publish", field("type", $.type_ref), repeat($._action_arg), $._newline, optional($.action_block)),

        cache_action: ($) => seq("cache", repeat($._action_arg), $._newline),

        cache_delete_action: ($) => seq("cache_delete", repeat($._action_arg), $._newline),

        withdraw_action: ($) => seq("withdraw", field("binding", $.identifier), $._newline),

        // [LGRA.10.1]: call_action; the service is one global name ([LGRA.10.1.6]).
        call_action: ($) => seq(
            "call",
            field("service", $.dotted_name),
            repeat($._action_arg),
            optional($.call_as),
            $._newline,
            optional($.action_block),
        ),

        call_as: ($) => seq("as", $._expression),

        // [LGRA.10.8]: an action's indented block.
        action_block: ($) => seq(
            $._indent,
            repeat1(choice(
                seq(repeat1($._action_arg), $._newline),
                seq($.call_as, $._newline),
                $.continuation,
            )),
            $._dedent,
        ),

        // [LCCO.2.1]: continuation.
        continuation: ($) => seq(
            choice(
                seq("on", field("condition", $._expression)),
                seq("timeout", field("duration", $._time_expr)),
                seq("error", optional(field("code", $.dotted_name))),
            ),
            ":",
            $._body,
        ),

        // [LGRA.10.3.1]: action_arg.
        _action_arg: ($) => choice($.kwarg, $.flag),

        kwarg: ($) => seq(field("name", $.identifier), ":", field("value", $._expression)),

        flag: ($) => $.identifier,

        // ── [LGRA.7.1] series ───────────────────────────────────────────────
        series_declaration: ($) => seq(
            "series",
            field("slot", $.dotted_name),
            optional($.series_options),
            ":",
            $._indent,
            optional($.docstring),
            repeat1($.series_line),
            $._dedent,
        ),

        // [LGRA.7.1]: block_opts; which kwargs a block takes is the validator's.
        series_options: ($) => seq("(", commaSep1($.kwarg), ")"),

        series_line: ($) => seq(
            commaSep1(field("aggregation", $.identifier)),
            $.time_model,
            optional($.accuracy),
            optional($.gap_policy),
            optional(seq("as", field("name", $.identifier))),
            $._newline,
        ),

        time_model: ($) => choice(
            "all_time",
            seq("sliding", $._time_expr),
            seq("tumbling", $._time_expr),
            seq("sample", $.integer),
        ),

        // [LGRA.7.1]: every accuracy phrase parses and is then refused
        // ([LSER.15.1]); `exact`, `confidence`, `delta` and `bound` are not
        // reserved, so the phrase is a NAME and what follows it.
        accuracy: ($) => choice(
            seq("tolerance", $._number),
            seq($.identifier, optional(choice($._number, $.identifier))),
        ),

        // [LGRA.7.6a]: gap_policy.
        gap_policy: ($) => seq("gap", choice("hold", "zero", "skip")),

        // ── [LGRA.23.1] services ────────────────────────────────────────────
        service_declaration: ($) => seq(
            "service",
            field("name", $.dotted_name),
            ":",
            $._indent,
            optional($.docstring),
            // that the response comes last is the validator's ([LGRA.23.2])
            repeat1(choice($.kwarg_declaration, $.response_declaration)),
            $._dedent,
        ),

        kwarg_declaration: ($) => seq(
            "kwarg",
            field("name", $.identifier),
            ":",
            field("type", $.type),
            optional("?"),
            repeat(choice(seq("default", optional("-"), $._literal), "literal", "required")),
            $._newline,
        ),

        response_declaration: ($) => seq(
            choice(seq("response", field("type", $.type)), seq("no", "response")),
            $._newline,
        ),

        // ── units ([LUNI.4]) ────────────────────────────────────────────────
        unit_declaration: ($) => seq("unit", choice(
            // [LUNI.4.1]: unit dimension
            seq("dimension", field("name", $.identifier), "storage", field("storage", $.identifier),
                "base", field("base", $.type), $._newline),
            // [LUNI.4.2]: unit scalar
            seq("scalar", field("name", $.identifier), "storage", field("storage", $.identifier),
                optional($.unit_label), $._newline),
            // [LUNI.4.5]: unit formula
            seq("formula", field("name", $.identifier), repeat(choice("inverting", "implicit")), ":",
                $._indent, repeat1($.formula_line), $._dedent),
            // [LUNI.4.6]: unit fx_pair, deferred; the compiler refuses it
            // ([LUNI.13.11])
            seq("fx_pair", field("name", $.type), ":", field("from", $.identifier), "to",
                field("to", $.identifier), $._indent, $.fx_via, $.fx_field, $._dedent),
            // [LUNI.4.3]: unit_symbol, tier 1
            seq(field("name", $.type), ":", field("dimension", $.identifier),
                optional(seq("=", field("to_base", $._expression))),
                optional($.unit_label), optional($.unit_aliases), $._newline),
            // [LUNI.4.3]: unit_symbol, tier 2
            seq(field("name", $.type), ":", field("dimension", $.identifier), ":", optional($.unit_label),
                $._indent, $.unit_conversion, $.unit_conversion, $._dedent),
        )),

        // [LUNI.4.3]: `label` is a keyword only before a string.
        unit_label: ($) => seq("label", $.string),

        unit_aliases: ($) => seq("alias", commaSep1($.type)),

        unit_conversion: ($) => seq(choice("to_base", "from_base"), ":", $._expression, $._newline),

        // [LUNI.4.5]: formula_line.
        formula_line: ($) => seq(
            field("name", $.identifier),
            "(", field("parameter", $.identifier), ":", field("parameter_type", $.type), ")",
            ":", field("type", $.type), "=", field("value", $._expression), $._newline,
        ),

        // [LUNI.4.6]: the rate's schema and its selector.
        fx_via: ($) => seq("via", field("schema", $.identifier), "where", field("selector", $._expression),
            $._newline),

        // [LUNI.4.6]: the rate's two Int slots, numerator first.
        fx_field: ($) => seq("field", field("numerator", $.identifier), "/", field("denominator", $.identifier),
            $._newline),

        // [LOPQ.2.1]: opaque type.
        opaque_declaration: ($) => seq("opaque", "type", field("name", $.identifier), "over", field("representation", $.type), $._newline),

        // ── [LGRA.21.1] tests ───────────────────────────────────────────────
        test_declaration: ($) => seq(
            "test",
            field("name", $.string),
            ":",
            $._indent,
            repeat1(choice($.test_until, $.test_inputs, $.initial_block, $.test_responses, $.test_produces)),
            $._dedent,
        ),

        test_until: ($) => seq("until", $._time_coord, $._newline),

        // [LGRA.21.1]: time_coord ::= UNIT_LIT | postfix. A UNIT_LIT is
        // itself a primary ([LGRA.9.6.1]), so both are a primary expression:
        // a relative offset, or an absolute `calendar.time(...)` call
        // ([LTSL.3.2]). The compiler refuses any other postfix, a quoted
        // stamp included ([LTSL.3.7]); the grammar does not.
        _time_coord: ($) => $._primary_expression,

        test_inputs: ($) => seq("inputs", ":", $._indent, repeat1($.test_at), $._dedent),

        test_at: ($) => seq("at", $._time_coord, ":", $._indent, repeat1($.test_fact), $._dedent),

        // [LGRA.21.1]: test_fact, reply_fact.
        test_fact: ($) => seq(field("type", $.type_ref), repeat($._action_arg), $._newline),

        // [LGRA.24.1]: initial_block, whose items are a test's `initial` items.
        initial_block: ($) => seq(
            "initial", ":", $._indent,
            repeat1(choice($.test_fact, $.cache_seed, $.cache_block)),
            $._dedent,
        ),

        cache_seed: ($) => seq("cache", field("key", $.string), ":", field("value", $._expression), $._newline),

        cache_block: ($) => seq("cache", ":", $._indent, repeat1($.cache_entry), $._dedent),

        cache_entry: ($) => seq(field("key", $.string), ":", field("value", $._expression), $._newline),

        test_responses: ($) => seq("responses", ":", $._indent, repeat1($.response_stub), $._dedent),

        response_stub: ($) => seq(
            "for", "call", field("service", $.dotted_name),
            repeat($.kwarg),
            optional(seq("as", field("correlation", $.string))),
            optional(seq("after", field("delay", $.unit_literal))),
            ":",
            $._indent,
            repeat1(choice($.test_fact, $.no_response)),
            $._dedent,
        ),

        no_response: ($) => seq("no", "response", $._newline),

        test_produces: ($) => seq("produces", ":", $._indent, repeat1($.assertion), $._dedent),

        // [LGRA.21.1]: test_assertion, with `never` its polarity.
        assertion: ($) => seq(
            optional("never"),
            choice(
                seq("activated", field("rule", $.identifier)),
                seq(choice("emitted", "published"), field("type", $.type_ref), repeat($.kwarg),
                    optional(seq(field("binding", $.identifier), $.where_clause))),
                seq("retracted", field("type", $.type_ref), repeat($._action_arg)),
                seq("called", field("service", $.dotted_name), optional(seq("as", field("correlation", $.string)))),
                seq("cached", field("key", $.string), optional(seq(":", field("value", $._expression)))),
                seq("cache_deleted", field("key", $.string)),
                seq("logged", field("level", $.identifier), optional(field("message", $.string))),
                seq("wm", choice(
                    seq("has", field("type", $.type_ref), repeat($.kwarg)),
                    seq("count", field("type", $.type_ref), "==", $.integer),
                    "empty",
                )),
            ),
            $._newline,
        ),

        // ── [LGRA.9] expressions ────────────────────────────────────────────
        _expression: ($) => choice(
            $.boolean_operator,
            $.not_operator,
            $.comparison_operator,
            $.is_operator,
            $.binary_operator,
            $.match_operator,
            $.unary_operator,
            $._primary_expression,
        ),

        // [LGRA.9.3.1]: or_expr, and_expr.
        boolean_operator: ($) => choice(
            prec.left(PREC.or, seq(field("left", $._expression), field("operator", "or"), field("right", $._expression))),
            prec.left(PREC.and, seq(field("left", $._expression), field("operator", "and"), field("right", $._expression))),
        ),

        not_operator: ($) => prec(PREC.not, seq("not", field("argument", $._expression))),

        // [LGRA.9.3.2]: comparisons chain, so the production is left-recursive.
        comparison_operator: ($) => prec.left(PREC.compare, seq(
            field("left", $._expression),
            field("operator", choice("==", "!=", "<", "<=", ">", ">=")),
            field("right", $._expression),
        )),

        // [LGRA.9.3.1], [LGRA.9.3.3]: `is` and `is not`, over a closed subject.
        is_operator: ($) => prec.left(PREC.compare, seq(
            field("left", $._expression),
            "is",
            optional("not"),
            field("subject", $.is_subject),
        )),

        is_subject: ($) => choice($.null, $.boolean, $.inf, seq("-", $.inf), $.nan, $.identifier),

        // [LGRA.9.3.1]: `~` and `!~` take a regex literal only ([LREG.5.5]).
        match_operator: ($) => prec.left(PREC.match, seq(
            field("left", $._expression),
            field("operator", choice("~", "!~")),
            field("pattern", $.regex),
        )),

        binary_operator: ($) => {
            /** @type {Array<[number, string[], boolean?]>} */
            const table = [
                [PREC.coalesce, ["??"]],
                [PREC.interval_rel, ["in", "contains", "overlaps"]],
                [PREC.interval, [".."]],
                [PREC.bit_or, ["|"]],
                [PREC.bit_xor, ["^"]],
                [PREC.bit_and, ["&"]],
                [PREC.shift, ["<<", ">>"]],
                [PREC.add, ["+", "-"]],
                [PREC.mul, ["*", "/", "//", "%"]],
                [PREC.pow, ["**"], true],
            ];
            return choice(...table.map(([p, ops, right]) => (right ? prec.right : prec.left)(p, seq(
                field("left", $._expression),
                field("operator", choice(...ops)),
                field("right", $._expression),
            ))));
        },

        // [LGRA.9.5.1]: unary, the arithmetic prefixes.
        unary_operator: ($) => prec(PREC.unary, seq(field("operator", choice("-", "+", "~")), field("argument", $._expression))),

        // [LGRA.9.6.1], [LGRA.9.7.1]: postfix and primary.
        _primary_expression: ($) => choice(
            $.identifier,
            $._literal,
            $.parenthesized_expression,
            $.attribute,
            $.subscript,
            $.call,
            $.cast,
        ),

        parenthesized_expression: ($) => seq("(", $._expression, ")"),

        attribute: ($) => prec(PREC.postfix, seq(field("object", $._primary_expression), ".", field("attribute", $.identifier))),

        subscript: ($) => prec(PREC.postfix, seq(field("value", $._primary_expression), "[", field("index", $._expression), "]")),

        call: ($) => prec(PREC.postfix, seq(field("function", $._primary_expression), $.argument_list)),

        argument_list: ($) => seq("(", optional(commaSep1($._expression)), ")"),

        // [LCST.4.1]: the `::` conversion cast.
        cast: ($) => prec(PREC.postfix, seq(field("value", $._primary_expression), "::", field("type", $.type), optional("?"))),

        // [LGRA.4.1]: literal.
        _literal: ($) => choice($.integer, $.float, $.unit_literal, $.string, $.boolean, $.null, $.inf, $.nan),

        _number: ($) => choice($.integer, $.float),

        boolean: ($) => choice("true", "false"),

        null: ($) => "null",

        inf: ($) => "inf",

        nan: ($) => "NaN",

        // ── lexical ([LGRA.2], [LLEX]) ──────────────────────────────────────
        // [LGRA.2.4.1]: comment.
        comment: ($) => token(seq("#", /.*/)),

        // [LLEX.10.1]: NAME over XID ([LNAM.2.2.1]).
        identifier: ($) => /[_\p{XID_Start}][\p{XID_Continue}]*/,

        // [LGRA.2.5.1]: a TYPE_SYM spelled with a non-XID unit glyph (`°C`, `%`).
        unit_symbol: ($) => token(seq(/[°′″%]/, /[°′″%\p{XID_Continue}]*/)),

        // The number tokens come before unit_literal: where two match the same
        // characters (`0x1F` is not 0 of unit `x1F`), tree-sitter takes the
        // earlier one, and a longer unit literal (`1e6_s`) still wins.
        // [LLEX.11.1]: INT_LIT.
        integer: ($) => token(choice(
            /0x[0-9A-Fa-f](_?[0-9A-Fa-f])*/,
            /0b[01](_?[01])*/,
            /0o[0-7](_?[0-7])*/,
            new RegExp(DEC),
        )),

        // [LLEX.11.2]: FLOAT_LIT, both sides of the point ([LLEX.11.2.1]).
        float: ($) => token(choice(
            new RegExp(`${DEC}\\.${DEC}(${EXP})?`),
            new RegExp(`${DEC}${EXP}`),
        )),

        // [LLEX.12]: UNIT_LIT ::= DEC_PREFIX '_'? UNIT_SUFFIX. [LLEX.11.3.1]
        // withholds an `e`/`E` followed by digits from the suffix, which leaves
        // `1e6` to FLOAT_LIT.
        unit_literal: ($) => token(new RegExp(
            `${DEC}(\\.${DEC})?(${EXP})?_?`
            + `([A-DF-Za-df-z${GLYPHS}][${UNIT_CONT}]*|[eE]([A-Za-z${GLYPHS}][${UNIT_CONT}]*)?)`,
        )),

        // [LREG.6.1]: a regex literal follows `~` or `!~` only, to the first
        // unescaped `/` ([LREG.6.4]), on one line ([LREG.6.5]), with its flags.
        regex: ($) => token(seq("/", /([^/\\\n]|\\.)+/, "/", /[A-Za-z]*/)),

        // [LGRA.2.9.1]: STRING_LIT.
        string: ($) => choice($._single_string, $._triple_string),

        _single_string: ($) => seq(
            '"',
            repeat(choice($.string_content, $.escape_sequence, $.brace_escape, $.interpolation)),
            token.immediate('"'),
        ),

        // [LGRA.2.9.3]: may span lines; no interpolation site is parsed in it.
        _triple_string: ($) => token(seq('"""', /([^"\\]|\\.|"[^"]|""[^"])*/, '"""')),

        // [LGRA.2.9.2]: no raw newline in a one-line string.
        string_content: ($) => token.immediate(prec(1, /[^"\\{}\n]+/)),

        // [LGRA.2.9.1]: ESCAPE_SEQ; an unknown escape parses and is refused
        // ([LGRA.2.9.4]).
        escape_sequence: ($) => token.immediate(prec(1, /\\(x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)/)),

        // [LGRA.2.9.6.7]: `{{` and `}}`.
        brace_escape: ($) => token.immediate(prec(2, choice("{{", "}}"))),

        // [LGRA.2.9.6.1]: interp_site, with no whitespace inside its braces
        // ([LGRA.2.9.6.6]).
        interpolation: ($) => seq(
            token.immediate("{"),
            alias(token.immediate(/[_\p{XID_Start}][\p{XID_Continue}]*/), $.identifier),
            repeat(choice(
                seq(token.immediate("."), alias(token.immediate(/[_\p{XID_Start}][\p{XID_Continue}]*/), $.identifier)),
                seq(token.immediate("["), alias(token.immediate(/[0-9]+/), $.integer), token.immediate("]")),
            )),
            optional(seq(token.immediate(":"), alias(token.immediate(/[^{}"\n]+/), $.format_spec))),
            token.immediate("}"),
        ),
    },
});

// GENERATED from tools/ds_ast/ds.asdl. Do not edit: regenerate it.
// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Schema sha256 (first 16): af29e1c6057eaf2f.
//
// ds_ast's nodes for JavaScript (tools/ds_ast/DESIGN.md section 3). A node
// is a plain object, as `dsc dump-ast` writes it, whose `_type` names its
// constructor. NODES gives every constructor's fields and attributes, which
// read.js checks a tree against; the typedefs below give `tsc --checkJs` the
// same shapes. An ASDL type is `<type>_t` (`expr_t`, `let_t`): a union of its
// constructors.

/** @typedef {"" | "?" | "*"} Kind  required, optional, or a sequence */
/** @typedef {{ name: string, type: string, kind: Kind }} Field */
/** @typedef {{ type: string, fields: readonly Field[], attributes: readonly Field[] }} Shape */

/** @typedef {{ _type: "Module", use: use_t | null, body: decl_t[], comments_end: comment_t[] }} Module */
/** @typedef {Module} mod_t */

/** @typedef {{ _type: "Use", dialect: string, settings: setting_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Use */
/** @typedef {Use} use_t */

/** @typedef {{ _type: "Setting", capability: string, value: boolean }} Setting */
/** @typedef {Setting} setting_t */

/** @typedef {{ _type: "Import", path: string[], asname: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Import */
/** @typedef {{ _type: "ImportFrom", path: string[], names: alias_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} ImportFrom */
/** @typedef {{ _type: "Schema", name: string, scope: scope_t | null, docstring: string | null, slots: slot_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Schema */
/** @typedef {{ _type: "Rule", name: string, rate: rate_t[], docstring: string | null, lhs: lhs_t[], lets: let_t[], actions: action_t[], afters: after_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Rule */
/** @typedef {{ _type: "Const", name: string, annotation: annotation_t | null, value: expr_t, colon_form: boolean, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Const */
/** @typedef {{ _type: "Series", schema: string | null, slot: string, options: series_option_t[], docstring: string | null, lines: series_line_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Series */
/** @typedef {{ _type: "Service", name: string[], docstring: string | null, kwargs: service_kwarg_t[], response: service_response_t | null, hydration: hydration_field_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Service */
/** @typedef {{ _type: "UnitDimension", name: string, storage: string, base: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} UnitDimension */
/** @typedef {{ _type: "UnitScalar", name: string, storage: string, label: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} UnitScalar */
/** @typedef {{ _type: "UnitSymbol", symbol: string, dimension: string, body: unit_body_t, label: string | null, aliases: string[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} UnitSymbol */
/** @typedef {{ _type: "UnitFormula", name: string, modifiers: formula_modifier_t[], lines: formula_line_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} UnitFormula */
/** @typedef {{ _type: "UnitFxPair", name: string, from_unit: string, to_unit: string, via: string, where: expr_t, numerator: string, denominator: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} UnitFxPair */
/** @typedef {{ _type: "Opaque", name: string, representation: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Opaque */
/** @typedef {{ _type: "Test", name: expr_t, sections: test_section_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Test */
/** @typedef {{ _type: "InitialBlock", items: initial_item_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} InitialBlock */
/** @typedef {Import | ImportFrom | Schema | Rule | Const | Series | Service | UnitDimension | UnitScalar | UnitSymbol | UnitFormula | UnitFxPair | Opaque | Test | InitialBlock} decl_t */

/** @typedef {{ _type: "Initial", items: initial_item_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Initial */
/** @typedef {{ _type: "Inputs", blocks: at_block_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Inputs */
/** @typedef {{ _type: "Responses", stubs: stub_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Responses */
/** @typedef {{ _type: "Produces", assertions: assertion_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Produces */
/** @typedef {{ _type: "Until", when: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Until */
/** @typedef {Initial | Inputs | Responses | Produces | Until} test_section_t */

/** @typedef {{ _type: "InitialFact", fact: fact_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} InitialFact */
/** @typedef {{ _type: "CacheSeed", key: expr_t, value: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} CacheSeed */
/** @typedef {{ _type: "CacheBlock", seeds: seed_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} CacheBlock */
/** @typedef {InitialFact | CacheSeed | CacheBlock} initial_item_t */

/** @typedef {{ _type: "Seed", key: expr_t, value: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Seed */
/** @typedef {Seed} seed_t */

/** @typedef {{ _type: "Fact", schema: type_ref_t, args: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Fact */
/** @typedef {Fact} fact_t */

/** @typedef {{ _type: "At", when: expr_t, facts: fact_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} At */
/** @typedef {At} at_block_t */

/** @typedef {{ _type: "ForCall", library: string[], service: string[], args: keyword_t[], correlation: expr_t | null, after: expr_t | null, replies: reply_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} ForCall */
/** @typedef {ForCall} stub_t */

/** @typedef {{ _type: "Reply", fact: fact_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Reply */
/** @typedef {{ _type: "NoResponse", lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} NoResponse */
/** @typedef {Reply | NoResponse} reply_t */

/** @typedef {{ _type: "Assertion", never: boolean, head: test_head_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Assertion */
/** @typedef {Assertion} assertion_t */

/** @typedef {{ _type: "Activated", rule: string }} Activated */
/** @typedef {{ _type: "Emitted", schema: type_ref_t, args: keyword_t[], binding: string | null, where: expr_t | null }} Emitted */
/** @typedef {{ _type: "Published", schema: type_ref_t, args: keyword_t[], binding: string | null, where: expr_t | null }} Published */
/** @typedef {{ _type: "Retracted", schema: type_ref_t, args: keyword_t[] }} Retracted */
/** @typedef {{ _type: "Recorded", kind: string }} Recorded */
/** @typedef {{ _type: "Called", library: string[], service: string[], correlation: expr_t | null }} Called */
/** @typedef {{ _type: "Cached", key: expr_t, value: expr_t | null }} Cached */
/** @typedef {{ _type: "CacheDeleted", key: expr_t }} CacheDeleted */
/** @typedef {{ _type: "Logged", level: log_level_t, substring: expr_t | null }} Logged */
/** @typedef {{ _type: "WmHas", schema: type_ref_t, args: keyword_t[] }} WmHas */
/** @typedef {{ _type: "WmCount", schema: type_ref_t, count: expr_t }} WmCount */
/** @typedef {{ _type: "WmEmpty" }} WmEmpty */
/** @typedef {Activated | Emitted | Published | Retracted | Recorded | Called | Cached | CacheDeleted | Logged | WmHas | WmCount | WmEmpty} test_head_t */

/** @typedef {{ _type: "alias", name: string, asname: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} alias */
/** @typedef {alias} alias_t */

/** @typedef {{ _type: "comment", text: string, lineno: number, col_offset: number, blank_lines_before: number }} comment */
/** @typedef {comment} comment_t */

/** @typedef {{ _type: "ResponseSchema", name: string }} ResponseSchema */
/** @typedef {{ _type: "NoServiceResponse" }} NoServiceResponse */
/** @typedef {ResponseSchema | NoServiceResponse} service_response_t */

/** @typedef {{ _type: "Explicit" }} Explicit */
/** @typedef {{ _type: "Activation" }} Activation */
/** @typedef {{ _type: "Logical", ambient: boolean }} Logical */
/** @typedef {{ _type: "Ttl", duration: expr_t, ambient: boolean }} Ttl */
/** @typedef {{ _type: "Unprefixed", scope: scope_t }} Unprefixed */
/** @typedef {{ _type: "BareAmbient" }} BareAmbient */
/** @typedef {Explicit | Activation | Logical | Ttl | Unprefixed | BareAmbient} scope_t */

/** @typedef {{ _type: "Slot", name: string, type: string, nullable: boolean, capacity: expr_t | null, markers: marker_t[], tolerance: expr_t | null, docstring: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Slot */
/** @typedef {Slot} slot_t */

/** @typedef {{ _type: "Key", lineno: number, col_offset: number }} Key */
/** @typedef {{ _type: "Mutable", lineno: number, col_offset: number }} Mutable */
/** @typedef {{ _type: "Sampled", lineno: number, col_offset: number }} Sampled */
/** @typedef {{ _type: "Retained", lineno: number, col_offset: number }} Retained */
/** @typedef {Key | Mutable | Sampled | Retained} marker_t */

/** @typedef {{ _type: "Cooldown", duration: expr_t, lineno: number, col_offset: number }} Cooldown */
/** @typedef {{ _type: "RateKey", paths: expr_t[], lineno: number, col_offset: number }} RateKey */
/** @typedef {Cooldown | RateKey} rate_t */

/** @typedef {{ _type: "PatternClause", pattern: pattern_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} PatternClause */
/** @typedef {{ _type: "ThenClause", step: then_step_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} ThenClause */
/** @typedef {PatternClause | ThenClause} lhs_t */

/** @typedef {{ _type: "Simple", body: pattern_body_t }} Simple */
/** @typedef {{ _type: "Negated", body: pattern_body_t, parenthesised: boolean }} Negated */
/** @typedef {{ _type: "Sequence", latest: boolean, head: pattern_body_t, steps: then_step_t[] }} Sequence */
/** @typedef {Simple | Negated | Sequence} pattern_t */

/** @typedef {{ _type: "PatternBody", type: type_ref_t, binding: string | null, within: expr_t | null, where: expr_t | null, captures: string[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} PatternBody */
/** @typedef {PatternBody} pattern_body_t */

/** @typedef {{ _type: "Then", latest: boolean, body: pattern_body_t, within: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Then */
/** @typedef {Then} then_step_t */

/** @typedef {{ _type: "TypeName", name: string }} TypeName */
/** @typedef {{ _type: "QualifiedType", library: string[], name: string }} QualifiedType */
/** @typedef {TypeName | QualifiedType} type_ref_t */

/** @typedef {{ _type: "Let", bindings: let_binding_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Let */
/** @typedef {Let} let_t */

/** @typedef {{ _type: "LetName", name: string, annotation: annotation_t | null, value: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} LetName */
/** @typedef {{ _type: "LetCapture", names: string[], value: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} LetCapture */
/** @typedef {LetName | LetCapture} let_binding_t */

/** @typedef {{ _type: "Annotation", type: string, nullable: boolean }} Annotation */
/** @typedef {Annotation} annotation_t */

/** @typedef {{ _type: "Log", level: log_level_t, message: expr_t, args: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Log */
/** @typedef {{ _type: "ServiceCall", library: string[], service: string[], args: keyword_t[], block: keyword_t[], continuations: continuation_t[], correlation: expr_t | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} ServiceCall */
/** @typedef {{ _type: "Emit", schema: type_ref_t, args: keyword_t[], block: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Emit */
/** @typedef {{ _type: "Publish", schema: type_ref_t, args: keyword_t[], block: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Publish */
/** @typedef {{ _type: "Cache", args: keyword_t[], block: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Cache */
/** @typedef {{ _type: "CacheDelete", args: keyword_t[], block: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} CacheDelete */
/** @typedef {{ _type: "RecordEvent", schema: type_ref_t, args: keyword_t[], block: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} RecordEvent */
/** @typedef {{ _type: "Withdraw", binding: string, args: keyword_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Withdraw */
/** @typedef {Log | ServiceCall | Emit | Publish | Cache | CacheDelete | RecordEvent | Withdraw} action_t */

/** @typedef {{ _type: "LogDebug" }} LogDebug */
/** @typedef {{ _type: "LogInfo" }} LogInfo */
/** @typedef {{ _type: "LogWarning" }} LogWarning */
/** @typedef {{ _type: "LogError" }} LogError */
/** @typedef {{ _type: "LogCritical" }} LogCritical */
/** @typedef {{ _type: "LogUnknown", written: string }} LogUnknown */
/** @typedef {LogDebug | LogInfo | LogWarning | LogError | LogCritical | LogUnknown} log_level_t */

/** @typedef {{ _type: "keyword", arg: string, value: expr_t | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} keyword */
/** @typedef {keyword} keyword_t */

/** @typedef {{ _type: "OnResponse", test: expr_t, body: action_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} OnResponse */
/** @typedef {{ _type: "OnTimeout", duration: expr_t, body: action_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} OnTimeout */
/** @typedef {{ _type: "OnError", code: string[], body: action_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} OnError */
/** @typedef {OnResponse | OnTimeout | OnError} continuation_t */

/** @typedef {{ _type: "After", duration: expr_t, correlation: expr_t | null, body: action_t[], nested: after_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} After */
/** @typedef {After} after_t */

/** @typedef {{ _type: "Persist", duration: expr_t, lineno: number, col_offset: number }} Persist */
/** @typedef {{ _type: "By", slot: string | null, lineno: number, col_offset: number }} By */
/** @typedef {{ _type: "Capacity", samples: expr_t, lineno: number, col_offset: number }} Capacity */
/** @typedef {{ _type: "Nulls", policy: string, lineno: number, col_offset: number }} Nulls */
/** @typedef {Persist | By | Capacity | Nulls} series_option_t */

/** @typedef {{ _type: "SeriesLine", aggregations: string[], time: time_model_t, accuracy: accuracy_t | null, gap: gap_policy_t | null, asname: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} SeriesLine */
/** @typedef {SeriesLine} series_line_t */

/** @typedef {{ _type: "AllTime" }} AllTime */
/** @typedef {{ _type: "Sliding", window: expr_t }} Sliding */
/** @typedef {{ _type: "Tumbling", window: expr_t }} Tumbling */
/** @typedef {{ _type: "Sample", size: expr_t }} Sample */
/** @typedef {AllTime | Sliding | Tumbling | Sample} time_model_t */

/** @typedef {{ _type: "Exact" }} Exact */
/** @typedef {{ _type: "Tolerance", value: expr_t }} Tolerance */
/** @typedef {{ _type: "Confidence", value: expr_t }} Confidence */
/** @typedef {{ _type: "Delta", value: expr_t }} Delta */
/** @typedef {{ _type: "BoundDeterministic" }} BoundDeterministic */
/** @typedef {Exact | Tolerance | Confidence | Delta | BoundDeterministic} accuracy_t */

/** @typedef {{ _type: "GapHold" }} GapHold */
/** @typedef {{ _type: "GapZero" }} GapZero */
/** @typedef {{ _type: "GapSkip" }} GapSkip */
/** @typedef {GapHold | GapZero | GapSkip} gap_policy_t */

/** @typedef {{ _type: "ServiceKwarg", name: string, type: string, modifiers: kwarg_modifier_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} ServiceKwarg */
/** @typedef {ServiceKwarg} service_kwarg_t */

/** @typedef {{ _type: "Default", value: expr_t }} Default */
/** @typedef {{ _type: "Literal" }} Literal */
/** @typedef {{ _type: "Required" }} Required */
/** @typedef {Default | Literal | Required} kwarg_modifier_t */

/** @typedef {{ _type: "Hydrates", schemas: string[], lineno: number, col_offset: number, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} Hydrates */
/** @typedef {{ _type: "MaxWindow", value: expr_t, lineno: number, col_offset: number, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} MaxWindow */
/** @typedef {{ _type: "MaxLimit", value: expr_t, lineno: number, col_offset: number, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} MaxLimit */
/** @typedef {{ _type: "FilterFields", fields: filter_field_t[], lineno: number, col_offset: number, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} FilterFields */
/** @typedef {Hydrates | MaxWindow | MaxLimit | FilterFields} hydration_field_t */

/** @typedef {{ _type: "FilterField", name: string, ops: cmpop_t[] }} FilterField */
/** @typedef {FilterField} filter_field_t */

/** @typedef {{ _type: "BaseUnit" }} BaseUnit */
/** @typedef {{ _type: "Affine", expr: expr_t }} Affine */
/** @typedef {{ _type: "Tier2", to_base: expr_t, from_base: expr_t }} Tier2 */
/** @typedef {BaseUnit | Affine | Tier2} unit_body_t */

/** @typedef {{ _type: "Inverting" }} Inverting */
/** @typedef {{ _type: "Implicit" }} Implicit */
/** @typedef {Inverting | Implicit} formula_modifier_t */

/** @typedef {{ _type: "FormulaLine", name: string, param: string, param_type: string, returns: string, body: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null, comments_before: comment_t[], comment_after: comment_t | null, blank_lines_before: number }} FormulaLine */
/** @typedef {FormulaLine} formula_line_t */

/** @typedef {{ _type: "BoolOp", op: boolop_t, values: expr_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} BoolOp */
/** @typedef {{ _type: "UnaryOp", op: unaryop_t, operand: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} UnaryOp */
/** @typedef {{ _type: "BinOp", left: expr_t, op: operator_t, right: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} BinOp */
/** @typedef {{ _type: "Compare", left: expr_t, ops: cmpop_t[], comparators: expr_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Compare */
/** @typedef {{ _type: "Is", operand: expr_t, negated: boolean, subject: is_subject_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Is */
/** @typedef {{ _type: "Match", operand: expr_t, negated: boolean, pattern: string, flags: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Match */
/** @typedef {{ _type: "Call", func: expr_t, args: expr_t[], lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Call */
/** @typedef {{ _type: "Cast", operand: expr_t, type: string, nullable: boolean, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Cast */
/** @typedef {{ _type: "Attribute", value: expr_t, attr: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Attribute */
/** @typedef {{ _type: "Subscript", value: expr_t, index: expr_t, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Subscript */
/** @typedef {{ _type: "Name", id: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Name */
/** @typedef {{ _type: "QualifiedName", library: string[], id: string, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} QualifiedName */
/** @typedef {{ _type: "Constant", value: number | string | boolean | null, raw: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Constant */
/** @typedef {{ _type: "Quantity", magnitude: string, unit: string, raw: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} Quantity */
/** @typedef {{ _type: "JoinedStr", values: expr_t[], raw: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} JoinedStr */
/** @typedef {{ _type: "FormattedValue", value: expr_t, format_spec: string | null, lineno: number, col_offset: number, end_lineno: number | null, end_col_offset: number | null }} FormattedValue */
/** @typedef {BoolOp | UnaryOp | BinOp | Compare | Is | Match | Call | Cast | Attribute | Subscript | Name | QualifiedName | Constant | Quantity | JoinedStr | FormattedValue} expr_t */

/** @typedef {{ _type: "And" }} And */
/** @typedef {{ _type: "Or" }} Or */
/** @typedef {And | Or} boolop_t */

/** @typedef {{ _type: "Add" }} Add */
/** @typedef {{ _type: "Sub" }} Sub */
/** @typedef {{ _type: "Mult" }} Mult */
/** @typedef {{ _type: "Div" }} Div */
/** @typedef {{ _type: "FloorDiv" }} FloorDiv */
/** @typedef {{ _type: "Mod" }} Mod */
/** @typedef {{ _type: "Pow" }} Pow */
/** @typedef {{ _type: "BitOr" }} BitOr */
/** @typedef {{ _type: "BitXor" }} BitXor */
/** @typedef {{ _type: "BitAnd" }} BitAnd */
/** @typedef {{ _type: "LShift" }} LShift */
/** @typedef {{ _type: "RShift" }} RShift */
/** @typedef {{ _type: "Coalesce" }} Coalesce */
/** @typedef {{ _type: "In" }} In */
/** @typedef {{ _type: "Contains" }} Contains */
/** @typedef {{ _type: "Overlaps" }} Overlaps */
/** @typedef {{ _type: "Range" }} Range */
/** @typedef {Add | Sub | Mult | Div | FloorDiv | Mod | Pow | BitOr | BitXor | BitAnd | LShift | RShift | Coalesce | In | Contains | Overlaps | Range} operator_t */

/** @typedef {{ _type: "Not" }} Not */
/** @typedef {{ _type: "UAdd" }} UAdd */
/** @typedef {{ _type: "USub" }} USub */
/** @typedef {{ _type: "Invert" }} Invert */
/** @typedef {Not | UAdd | USub | Invert} unaryop_t */

/** @typedef {{ _type: "Eq" }} Eq */
/** @typedef {{ _type: "NotEq" }} NotEq */
/** @typedef {{ _type: "Lt" }} Lt */
/** @typedef {{ _type: "LtE" }} LtE */
/** @typedef {{ _type: "Gt" }} Gt */
/** @typedef {{ _type: "GtE" }} GtE */
/** @typedef {Eq | NotEq | Lt | LtE | Gt | GtE} cmpop_t */

/** @typedef {{ _type: "IsNull" }} IsNull */
/** @typedef {{ _type: "IsBool", value: boolean }} IsBool */
/** @typedef {{ _type: "IsInf", negative: boolean }} IsInf */
/** @typedef {{ _type: "IsNaN" }} IsNaN */
/** @typedef {{ _type: "IsTag", tag: string }} IsTag */
/** @typedef {IsNull | IsBool | IsInf | IsNaN | IsTag} is_subject_t */

/** @typedef {Module | Use | Setting | Import | ImportFrom | Schema | Rule | Const | Series | Service | UnitDimension | UnitScalar | UnitSymbol | UnitFormula | UnitFxPair | Opaque | Test | InitialBlock | Initial | Inputs | Responses | Produces | Until | InitialFact | CacheSeed | CacheBlock | Seed | Fact | At | ForCall | Reply | NoResponse | Assertion | Activated | Emitted | Published | Retracted | Recorded | Called | Cached | CacheDeleted | Logged | WmHas | WmCount | WmEmpty | alias | comment | ResponseSchema | NoServiceResponse | Explicit | Activation | Logical | Ttl | Unprefixed | BareAmbient | Slot | Key | Mutable | Sampled | Retained | Cooldown | RateKey | PatternClause | ThenClause | Simple | Negated | Sequence | PatternBody | Then | TypeName | QualifiedType | Let | LetName | LetCapture | Annotation | Log | ServiceCall | Emit | Publish | Cache | CacheDelete | RecordEvent | Withdraw | LogDebug | LogInfo | LogWarning | LogError | LogCritical | LogUnknown | keyword | OnResponse | OnTimeout | OnError | After | Persist | By | Capacity | Nulls | SeriesLine | AllTime | Sliding | Tumbling | Sample | Exact | Tolerance | Confidence | Delta | BoundDeterministic | GapHold | GapZero | GapSkip | ServiceKwarg | Default | Literal | Required | Hydrates | MaxWindow | MaxLimit | FilterFields | FilterField | BaseUnit | Affine | Tier2 | Inverting | Implicit | FormulaLine | BoolOp | UnaryOp | BinOp | Compare | Is | Match | Call | Cast | Attribute | Subscript | Name | QualifiedName | Constant | Quantity | JoinedStr | FormattedValue | And | Or | Add | Sub | Mult | Div | FloorDiv | Mod | Pow | BitOr | BitXor | BitAnd | LShift | RShift | Coalesce | In | Contains | Overlaps | Range | Not | UAdd | USub | Invert | Eq | NotEq | Lt | LtE | Gt | GtE | IsNull | IsBool | IsInf | IsNaN | IsTag} Node  every node */

/**
 * Every constructor, by name: the ASDL type it belongs to, its fields
 * and its attributes, in the order ds.asdl gives them.
 * @type {ReadonlyMap<string, Shape>}
 */
export const NODES = new Map([
    ["Module", { type: "mod", fields: [{ name: "use", type: "use", kind: "?" }, { name: "body", type: "decl", kind: "*" }, { name: "comments_end", type: "comment", kind: "*" }],
              attributes: [] }],
    ["Use", { type: "use", fields: [{ name: "dialect", type: "identifier", kind: "" }, { name: "settings", type: "setting", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Setting", { type: "setting", fields: [{ name: "capability", type: "identifier", kind: "" }, { name: "value", type: "bool", kind: "" }],
              attributes: [] }],
    ["Import", { type: "decl", fields: [{ name: "path", type: "identifier", kind: "*" }, { name: "asname", type: "identifier", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["ImportFrom", { type: "decl", fields: [{ name: "path", type: "identifier", kind: "*" }, { name: "names", type: "alias", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Schema", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "scope", type: "scope", kind: "?" }, { name: "docstring", type: "string", kind: "?" }, { name: "slots", type: "slot", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Rule", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "rate", type: "rate", kind: "*" }, { name: "docstring", type: "string", kind: "?" }, { name: "lhs", type: "lhs", kind: "*" }, { name: "lets", type: "let", kind: "*" }, { name: "actions", type: "action", kind: "*" }, { name: "afters", type: "after", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Const", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "annotation", type: "annotation", kind: "?" }, { name: "value", type: "expr", kind: "" }, { name: "colon_form", type: "bool", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Series", { type: "decl", fields: [{ name: "schema", type: "identifier", kind: "?" }, { name: "slot", type: "identifier", kind: "" }, { name: "options", type: "series_option", kind: "*" }, { name: "docstring", type: "string", kind: "?" }, { name: "lines", type: "series_line", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Service", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "*" }, { name: "docstring", type: "string", kind: "?" }, { name: "kwargs", type: "service_kwarg", kind: "*" }, { name: "response", type: "service_response", kind: "?" }, { name: "hydration", type: "hydration_field", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["UnitDimension", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "storage", type: "identifier", kind: "" }, { name: "base", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["UnitScalar", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "storage", type: "identifier", kind: "" }, { name: "label", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["UnitSymbol", { type: "decl", fields: [{ name: "symbol", type: "identifier", kind: "" }, { name: "dimension", type: "identifier", kind: "" }, { name: "body", type: "unit_body", kind: "" }, { name: "label", type: "string", kind: "?" }, { name: "aliases", type: "identifier", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["UnitFormula", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "modifiers", type: "formula_modifier", kind: "*" }, { name: "lines", type: "formula_line", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["UnitFxPair", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "from_unit", type: "identifier", kind: "" }, { name: "to_unit", type: "identifier", kind: "" }, { name: "via", type: "identifier", kind: "" }, { name: "where", type: "expr", kind: "" }, { name: "numerator", type: "identifier", kind: "" }, { name: "denominator", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Opaque", { type: "decl", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "representation", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Test", { type: "decl", fields: [{ name: "name", type: "expr", kind: "" }, { name: "sections", type: "test_section", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["InitialBlock", { type: "decl", fields: [{ name: "items", type: "initial_item", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Initial", { type: "test_section", fields: [{ name: "items", type: "initial_item", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Inputs", { type: "test_section", fields: [{ name: "blocks", type: "at_block", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Responses", { type: "test_section", fields: [{ name: "stubs", type: "stub", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Produces", { type: "test_section", fields: [{ name: "assertions", type: "assertion", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Until", { type: "test_section", fields: [{ name: "when", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["InitialFact", { type: "initial_item", fields: [{ name: "fact", type: "fact", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["CacheSeed", { type: "initial_item", fields: [{ name: "key", type: "expr", kind: "" }, { name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["CacheBlock", { type: "initial_item", fields: [{ name: "seeds", type: "seed", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Seed", { type: "seed", fields: [{ name: "key", type: "expr", kind: "" }, { name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Fact", { type: "fact", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["At", { type: "at_block", fields: [{ name: "when", type: "expr", kind: "" }, { name: "facts", type: "fact", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["ForCall", { type: "stub", fields: [{ name: "library", type: "identifier", kind: "*" }, { name: "service", type: "identifier", kind: "*" }, { name: "args", type: "keyword", kind: "*" }, { name: "correlation", type: "expr", kind: "?" }, { name: "after", type: "expr", kind: "?" }, { name: "replies", type: "reply", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Reply", { type: "reply", fields: [{ name: "fact", type: "fact", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["NoResponse", { type: "reply", fields: [],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Assertion", { type: "assertion", fields: [{ name: "never", type: "bool", kind: "" }, { name: "head", type: "test_head", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Activated", { type: "test_head", fields: [{ name: "rule", type: "identifier", kind: "" }],
              attributes: [] }],
    ["Emitted", { type: "test_head", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }, { name: "binding", type: "identifier", kind: "?" }, { name: "where", type: "expr", kind: "?" }],
              attributes: [] }],
    ["Published", { type: "test_head", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }, { name: "binding", type: "identifier", kind: "?" }, { name: "where", type: "expr", kind: "?" }],
              attributes: [] }],
    ["Retracted", { type: "test_head", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }],
              attributes: [] }],
    ["Recorded", { type: "test_head", fields: [{ name: "kind", type: "identifier", kind: "" }],
              attributes: [] }],
    ["Called", { type: "test_head", fields: [{ name: "library", type: "identifier", kind: "*" }, { name: "service", type: "identifier", kind: "*" }, { name: "correlation", type: "expr", kind: "?" }],
              attributes: [] }],
    ["Cached", { type: "test_head", fields: [{ name: "key", type: "expr", kind: "" }, { name: "value", type: "expr", kind: "?" }],
              attributes: [] }],
    ["CacheDeleted", { type: "test_head", fields: [{ name: "key", type: "expr", kind: "" }],
              attributes: [] }],
    ["Logged", { type: "test_head", fields: [{ name: "level", type: "log_level", kind: "" }, { name: "substring", type: "expr", kind: "?" }],
              attributes: [] }],
    ["WmHas", { type: "test_head", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }],
              attributes: [] }],
    ["WmCount", { type: "test_head", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "count", type: "expr", kind: "" }],
              attributes: [] }],
    ["WmEmpty", { type: "test_head", fields: [],
              attributes: [] }],
    ["alias", { type: "alias", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "asname", type: "identifier", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["comment", { type: "comment", fields: [{ name: "text", type: "string", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["ResponseSchema", { type: "service_response", fields: [{ name: "name", type: "identifier", kind: "" }],
              attributes: [] }],
    ["NoServiceResponse", { type: "service_response", fields: [],
              attributes: [] }],
    ["Explicit", { type: "scope", fields: [],
              attributes: [] }],
    ["Activation", { type: "scope", fields: [],
              attributes: [] }],
    ["Logical", { type: "scope", fields: [{ name: "ambient", type: "bool", kind: "" }],
              attributes: [] }],
    ["Ttl", { type: "scope", fields: [{ name: "duration", type: "expr", kind: "" }, { name: "ambient", type: "bool", kind: "" }],
              attributes: [] }],
    ["Unprefixed", { type: "scope", fields: [{ name: "scope", type: "scope", kind: "" }],
              attributes: [] }],
    ["BareAmbient", { type: "scope", fields: [],
              attributes: [] }],
    ["Slot", { type: "slot", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "type", type: "identifier", kind: "" }, { name: "nullable", type: "bool", kind: "" }, { name: "capacity", type: "expr", kind: "?" }, { name: "markers", type: "marker", kind: "*" }, { name: "tolerance", type: "expr", kind: "?" }, { name: "docstring", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Key", { type: "marker", fields: [],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Mutable", { type: "marker", fields: [],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Sampled", { type: "marker", fields: [],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Retained", { type: "marker", fields: [],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Cooldown", { type: "rate", fields: [{ name: "duration", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["RateKey", { type: "rate", fields: [{ name: "paths", type: "expr", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["PatternClause", { type: "lhs", fields: [{ name: "pattern", type: "pattern", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["ThenClause", { type: "lhs", fields: [{ name: "step", type: "then_step", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Simple", { type: "pattern", fields: [{ name: "body", type: "pattern_body", kind: "" }],
              attributes: [] }],
    ["Negated", { type: "pattern", fields: [{ name: "body", type: "pattern_body", kind: "" }, { name: "parenthesised", type: "bool", kind: "" }],
              attributes: [] }],
    ["Sequence", { type: "pattern", fields: [{ name: "latest", type: "bool", kind: "" }, { name: "head", type: "pattern_body", kind: "" }, { name: "steps", type: "then_step", kind: "*" }],
              attributes: [] }],
    ["PatternBody", { type: "pattern_body", fields: [{ name: "type", type: "type_ref", kind: "" }, { name: "binding", type: "identifier", kind: "?" }, { name: "within", type: "expr", kind: "?" }, { name: "where", type: "expr", kind: "?" }, { name: "captures", type: "identifier", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Then", { type: "then_step", fields: [{ name: "latest", type: "bool", kind: "" }, { name: "body", type: "pattern_body", kind: "" }, { name: "within", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["TypeName", { type: "type_ref", fields: [{ name: "name", type: "identifier", kind: "" }],
              attributes: [] }],
    ["QualifiedType", { type: "type_ref", fields: [{ name: "library", type: "identifier", kind: "*" }, { name: "name", type: "identifier", kind: "" }],
              attributes: [] }],
    ["Let", { type: "let", fields: [{ name: "bindings", type: "let_binding", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["LetName", { type: "let_binding", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "annotation", type: "annotation", kind: "?" }, { name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["LetCapture", { type: "let_binding", fields: [{ name: "names", type: "identifier", kind: "*" }, { name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Annotation", { type: "annotation", fields: [{ name: "type", type: "identifier", kind: "" }, { name: "nullable", type: "bool", kind: "" }],
              attributes: [] }],
    ["Log", { type: "action", fields: [{ name: "level", type: "log_level", kind: "" }, { name: "message", type: "expr", kind: "" }, { name: "args", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["ServiceCall", { type: "action", fields: [{ name: "library", type: "identifier", kind: "*" }, { name: "service", type: "identifier", kind: "*" }, { name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }, { name: "continuations", type: "continuation", kind: "*" }, { name: "correlation", type: "expr", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Emit", { type: "action", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Publish", { type: "action", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Cache", { type: "action", fields: [{ name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["CacheDelete", { type: "action", fields: [{ name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["RecordEvent", { type: "action", fields: [{ name: "schema", type: "type_ref", kind: "" }, { name: "args", type: "keyword", kind: "*" }, { name: "block", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Withdraw", { type: "action", fields: [{ name: "binding", type: "identifier", kind: "" }, { name: "args", type: "keyword", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["LogDebug", { type: "log_level", fields: [],
              attributes: [] }],
    ["LogInfo", { type: "log_level", fields: [],
              attributes: [] }],
    ["LogWarning", { type: "log_level", fields: [],
              attributes: [] }],
    ["LogError", { type: "log_level", fields: [],
              attributes: [] }],
    ["LogCritical", { type: "log_level", fields: [],
              attributes: [] }],
    ["LogUnknown", { type: "log_level", fields: [{ name: "written", type: "string", kind: "" }],
              attributes: [] }],
    ["keyword", { type: "keyword", fields: [{ name: "arg", type: "identifier", kind: "" }, { name: "value", type: "expr", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["OnResponse", { type: "continuation", fields: [{ name: "test", type: "expr", kind: "" }, { name: "body", type: "action", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["OnTimeout", { type: "continuation", fields: [{ name: "duration", type: "expr", kind: "" }, { name: "body", type: "action", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["OnError", { type: "continuation", fields: [{ name: "code", type: "identifier", kind: "*" }, { name: "body", type: "action", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["After", { type: "after", fields: [{ name: "duration", type: "expr", kind: "" }, { name: "correlation", type: "expr", kind: "?" }, { name: "body", type: "action", kind: "*" }, { name: "nested", type: "after", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Persist", { type: "series_option", fields: [{ name: "duration", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["By", { type: "series_option", fields: [{ name: "slot", type: "identifier", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Capacity", { type: "series_option", fields: [{ name: "samples", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["Nulls", { type: "series_option", fields: [{ name: "policy", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }] }],
    ["SeriesLine", { type: "series_line", fields: [{ name: "aggregations", type: "identifier", kind: "*" }, { name: "time", type: "time_model", kind: "" }, { name: "accuracy", type: "accuracy", kind: "?" }, { name: "gap", type: "gap_policy", kind: "?" }, { name: "asname", type: "identifier", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["AllTime", { type: "time_model", fields: [],
              attributes: [] }],
    ["Sliding", { type: "time_model", fields: [{ name: "window", type: "expr", kind: "" }],
              attributes: [] }],
    ["Tumbling", { type: "time_model", fields: [{ name: "window", type: "expr", kind: "" }],
              attributes: [] }],
    ["Sample", { type: "time_model", fields: [{ name: "size", type: "expr", kind: "" }],
              attributes: [] }],
    ["Exact", { type: "accuracy", fields: [],
              attributes: [] }],
    ["Tolerance", { type: "accuracy", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [] }],
    ["Confidence", { type: "accuracy", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [] }],
    ["Delta", { type: "accuracy", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [] }],
    ["BoundDeterministic", { type: "accuracy", fields: [],
              attributes: [] }],
    ["GapHold", { type: "gap_policy", fields: [],
              attributes: [] }],
    ["GapZero", { type: "gap_policy", fields: [],
              attributes: [] }],
    ["GapSkip", { type: "gap_policy", fields: [],
              attributes: [] }],
    ["ServiceKwarg", { type: "service_kwarg", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "type", type: "identifier", kind: "" }, { name: "modifiers", type: "kwarg_modifier", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["Default", { type: "kwarg_modifier", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [] }],
    ["Literal", { type: "kwarg_modifier", fields: [],
              attributes: [] }],
    ["Required", { type: "kwarg_modifier", fields: [],
              attributes: [] }],
    ["Hydrates", { type: "hydration_field", fields: [{ name: "schemas", type: "identifier", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["MaxWindow", { type: "hydration_field", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["MaxLimit", { type: "hydration_field", fields: [{ name: "value", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["FilterFields", { type: "hydration_field", fields: [{ name: "fields", type: "filter_field", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["FilterField", { type: "filter_field", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "ops", type: "cmpop", kind: "*" }],
              attributes: [] }],
    ["BaseUnit", { type: "unit_body", fields: [],
              attributes: [] }],
    ["Affine", { type: "unit_body", fields: [{ name: "expr", type: "expr", kind: "" }],
              attributes: [] }],
    ["Tier2", { type: "unit_body", fields: [{ name: "to_base", type: "expr", kind: "" }, { name: "from_base", type: "expr", kind: "" }],
              attributes: [] }],
    ["Inverting", { type: "formula_modifier", fields: [],
              attributes: [] }],
    ["Implicit", { type: "formula_modifier", fields: [],
              attributes: [] }],
    ["FormulaLine", { type: "formula_line", fields: [{ name: "name", type: "identifier", kind: "" }, { name: "param", type: "identifier", kind: "" }, { name: "param_type", type: "identifier", kind: "" }, { name: "returns", type: "identifier", kind: "" }, { name: "body", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }, { name: "comments_before", type: "comment", kind: "*" }, { name: "comment_after", type: "comment", kind: "?" }, { name: "blank_lines_before", type: "int", kind: "" }] }],
    ["BoolOp", { type: "expr", fields: [{ name: "op", type: "boolop", kind: "" }, { name: "values", type: "expr", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["UnaryOp", { type: "expr", fields: [{ name: "op", type: "unaryop", kind: "" }, { name: "operand", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["BinOp", { type: "expr", fields: [{ name: "left", type: "expr", kind: "" }, { name: "op", type: "operator", kind: "" }, { name: "right", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Compare", { type: "expr", fields: [{ name: "left", type: "expr", kind: "" }, { name: "ops", type: "cmpop", kind: "*" }, { name: "comparators", type: "expr", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Is", { type: "expr", fields: [{ name: "operand", type: "expr", kind: "" }, { name: "negated", type: "bool", kind: "" }, { name: "subject", type: "is_subject", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Match", { type: "expr", fields: [{ name: "operand", type: "expr", kind: "" }, { name: "negated", type: "bool", kind: "" }, { name: "pattern", type: "string", kind: "" }, { name: "flags", type: "string", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Call", { type: "expr", fields: [{ name: "func", type: "expr", kind: "" }, { name: "args", type: "expr", kind: "*" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Cast", { type: "expr", fields: [{ name: "operand", type: "expr", kind: "" }, { name: "type", type: "identifier", kind: "" }, { name: "nullable", type: "bool", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Attribute", { type: "expr", fields: [{ name: "value", type: "expr", kind: "" }, { name: "attr", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Subscript", { type: "expr", fields: [{ name: "value", type: "expr", kind: "" }, { name: "index", type: "expr", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Name", { type: "expr", fields: [{ name: "id", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["QualifiedName", { type: "expr", fields: [{ name: "library", type: "identifier", kind: "*" }, { name: "id", type: "identifier", kind: "" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Constant", { type: "expr", fields: [{ name: "value", type: "constant", kind: "" }, { name: "raw", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["Quantity", { type: "expr", fields: [{ name: "magnitude", type: "string", kind: "" }, { name: "unit", type: "string", kind: "" }, { name: "raw", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["JoinedStr", { type: "expr", fields: [{ name: "values", type: "expr", kind: "*" }, { name: "raw", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["FormattedValue", { type: "expr", fields: [{ name: "value", type: "expr", kind: "" }, { name: "format_spec", type: "string", kind: "?" }],
              attributes: [{ name: "lineno", type: "int", kind: "" }, { name: "col_offset", type: "int", kind: "" }, { name: "end_lineno", type: "int", kind: "?" }, { name: "end_col_offset", type: "int", kind: "?" }] }],
    ["And", { type: "boolop", fields: [],
              attributes: [] }],
    ["Or", { type: "boolop", fields: [],
              attributes: [] }],
    ["Add", { type: "operator", fields: [],
              attributes: [] }],
    ["Sub", { type: "operator", fields: [],
              attributes: [] }],
    ["Mult", { type: "operator", fields: [],
              attributes: [] }],
    ["Div", { type: "operator", fields: [],
              attributes: [] }],
    ["FloorDiv", { type: "operator", fields: [],
              attributes: [] }],
    ["Mod", { type: "operator", fields: [],
              attributes: [] }],
    ["Pow", { type: "operator", fields: [],
              attributes: [] }],
    ["BitOr", { type: "operator", fields: [],
              attributes: [] }],
    ["BitXor", { type: "operator", fields: [],
              attributes: [] }],
    ["BitAnd", { type: "operator", fields: [],
              attributes: [] }],
    ["LShift", { type: "operator", fields: [],
              attributes: [] }],
    ["RShift", { type: "operator", fields: [],
              attributes: [] }],
    ["Coalesce", { type: "operator", fields: [],
              attributes: [] }],
    ["In", { type: "operator", fields: [],
              attributes: [] }],
    ["Contains", { type: "operator", fields: [],
              attributes: [] }],
    ["Overlaps", { type: "operator", fields: [],
              attributes: [] }],
    ["Range", { type: "operator", fields: [],
              attributes: [] }],
    ["Not", { type: "unaryop", fields: [],
              attributes: [] }],
    ["UAdd", { type: "unaryop", fields: [],
              attributes: [] }],
    ["USub", { type: "unaryop", fields: [],
              attributes: [] }],
    ["Invert", { type: "unaryop", fields: [],
              attributes: [] }],
    ["Eq", { type: "cmpop", fields: [],
              attributes: [] }],
    ["NotEq", { type: "cmpop", fields: [],
              attributes: [] }],
    ["Lt", { type: "cmpop", fields: [],
              attributes: [] }],
    ["LtE", { type: "cmpop", fields: [],
              attributes: [] }],
    ["Gt", { type: "cmpop", fields: [],
              attributes: [] }],
    ["GtE", { type: "cmpop", fields: [],
              attributes: [] }],
    ["IsNull", { type: "is_subject", fields: [],
              attributes: [] }],
    ["IsBool", { type: "is_subject", fields: [{ name: "value", type: "bool", kind: "" }],
              attributes: [] }],
    ["IsInf", { type: "is_subject", fields: [{ name: "negative", type: "bool", kind: "" }],
              attributes: [] }],
    ["IsNaN", { type: "is_subject", fields: [],
              attributes: [] }],
    ["IsTag", { type: "is_subject", fields: [{ name: "tag", type: "identifier", kind: "" }],
              attributes: [] }],
]);

/**
 * Every ASDL type, with its constructors.
 * @type {ReadonlyMap<string, readonly string[]>}
 */
export const TYPES = new Map([
    ["mod", ["Module"]],
    ["use", ["Use"]],
    ["setting", ["Setting"]],
    ["decl", ["Import", "ImportFrom", "Schema", "Rule", "Const", "Series", "Service", "UnitDimension", "UnitScalar", "UnitSymbol", "UnitFormula", "UnitFxPair", "Opaque", "Test", "InitialBlock"]],
    ["test_section", ["Initial", "Inputs", "Responses", "Produces", "Until"]],
    ["initial_item", ["InitialFact", "CacheSeed", "CacheBlock"]],
    ["seed", ["Seed"]],
    ["fact", ["Fact"]],
    ["at_block", ["At"]],
    ["stub", ["ForCall"]],
    ["reply", ["Reply", "NoResponse"]],
    ["assertion", ["Assertion"]],
    ["test_head", ["Activated", "Emitted", "Published", "Retracted", "Recorded", "Called", "Cached", "CacheDeleted", "Logged", "WmHas", "WmCount", "WmEmpty"]],
    ["alias", ["alias"]],
    ["comment", ["comment"]],
    ["service_response", ["ResponseSchema", "NoServiceResponse"]],
    ["scope", ["Explicit", "Activation", "Logical", "Ttl", "Unprefixed", "BareAmbient"]],
    ["slot", ["Slot"]],
    ["marker", ["Key", "Mutable", "Sampled", "Retained"]],
    ["rate", ["Cooldown", "RateKey"]],
    ["lhs", ["PatternClause", "ThenClause"]],
    ["pattern", ["Simple", "Negated", "Sequence"]],
    ["pattern_body", ["PatternBody"]],
    ["then_step", ["Then"]],
    ["type_ref", ["TypeName", "QualifiedType"]],
    ["let", ["Let"]],
    ["let_binding", ["LetName", "LetCapture"]],
    ["annotation", ["Annotation"]],
    ["action", ["Log", "ServiceCall", "Emit", "Publish", "Cache", "CacheDelete", "RecordEvent", "Withdraw"]],
    ["log_level", ["LogDebug", "LogInfo", "LogWarning", "LogError", "LogCritical", "LogUnknown"]],
    ["keyword", ["keyword"]],
    ["continuation", ["OnResponse", "OnTimeout", "OnError"]],
    ["after", ["After"]],
    ["series_option", ["Persist", "By", "Capacity", "Nulls"]],
    ["series_line", ["SeriesLine"]],
    ["time_model", ["AllTime", "Sliding", "Tumbling", "Sample"]],
    ["accuracy", ["Exact", "Tolerance", "Confidence", "Delta", "BoundDeterministic"]],
    ["gap_policy", ["GapHold", "GapZero", "GapSkip"]],
    ["service_kwarg", ["ServiceKwarg"]],
    ["kwarg_modifier", ["Default", "Literal", "Required"]],
    ["hydration_field", ["Hydrates", "MaxWindow", "MaxLimit", "FilterFields"]],
    ["filter_field", ["FilterField"]],
    ["unit_body", ["BaseUnit", "Affine", "Tier2"]],
    ["formula_modifier", ["Inverting", "Implicit"]],
    ["formula_line", ["FormulaLine"]],
    ["expr", ["BoolOp", "UnaryOp", "BinOp", "Compare", "Is", "Match", "Call", "Cast", "Attribute", "Subscript", "Name", "QualifiedName", "Constant", "Quantity", "JoinedStr", "FormattedValue"]],
    ["boolop", ["And", "Or"]],
    ["operator", ["Add", "Sub", "Mult", "Div", "FloorDiv", "Mod", "Pow", "BitOr", "BitXor", "BitAnd", "LShift", "RShift", "Coalesce", "In", "Contains", "Overlaps", "Range"]],
    ["unaryop", ["Not", "UAdd", "USub", "Invert"]],
    ["cmpop", ["Eq", "NotEq", "Lt", "LtE", "Gt", "GtE"]],
    ["is_subject", ["IsNull", "IsBool", "IsInf", "IsNaN", "IsTag"]],
]);

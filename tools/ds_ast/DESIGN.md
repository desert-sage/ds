<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds_ast` — design

The first step of retiring the Python compiler. The requirements:

- **Shaped like Python's own `ast`.** Someone who reads and writes Python with
  `ast` should find nothing surprising here.
- **Four jobs:** read a program into a tree, transform the tree, write it back
  out as DS source, and build a new program from nodes.
- **Comments are kept**, and so are literal spellings and blank lines (§6):
  the places this goes beyond Python.
- **`ds_ast`, its own wheel.** It needs the `dsc` binary and not libds.

---

## 1. What the tree is: the Mercury CST, not the AST

The Mercury compiler has two trees. `dsc.cst` is "what the grammar produced,
with the source positions still attached and nothing desugared". `dsc.ast` is
what `build` makes of it, and `build` fills in defaults: an omitted `scope`
becomes `scope explicit` ([LSCP.1.4]).

**`ds_ast` mirrors the CST.** Python's `ast` is abstract about layout and
concrete about content: it drops parentheses and whitespace but never adds
something the author did not write. The CST draws the same line, and in
places it draws it on purpose for the same reason `ds_ast` needs it:

- `sd_lifecycle` is a `maybe`, because "a CST that silently fills in what the
  author did not write cannot answer 'did they say it?'";
- a negated pattern records its parentheses ([LGRA.8.4.2]);
- slot markers keep their order and duplicates;
- an expression records no parentheses, because the tree is the grouping.
  That matches Python, whose `unparse` inserts them by precedence.

So `unparse` writes a program whose meaning is the source's, and it can do
that without undoing any defaulting.

## 2. What the CST cannot carry yet, and must before `unparse` is faithful

Found while reading `dsc.cst.m`, `dsc.expr.m` and `dsc.lex.m`:

| Gap | Where | What it takes |
|---|---|---|
| **Comments are discarded.** The lexer scans a comment's text for bidi safety ([LNAM.2.6.3]) and throws it away, and [LLEX.5.2] gives a comment-only line no token. | `dsc.lex` | A side list of comments with their positions, returned beside the token lines and never entering them, so layout ([LLEX.5]–[LLEX.7]) is untouched. |
| **Three constructs are held as raw token spans**, not expressions: `scope ttl <dur>`, `cooldown`, `within`. | `lc_ttl`, `rm_cooldown`, `pb_within`, `ts_within` | **`dump-ast` parses each span with the compiler's own `lgra_9_1_parse_expr`** as it writes the JSON. The CST keeps its spans: about forty sites in `build`, `validate`, `rete` and `cycle` read them, and changing that is a compiler refactor `ds_ast` does not need. |
| **`test` declarations are not built.** `td_test(unbuilt(...))` records the keyword and nothing else, so `.dstest` programs have no tree. | `dsc.parse` | **Done in A6.** The `test` grammar ([LTSL.2.1]) built out into CST nodes and `ds.asdl`'s `Test` family, from the clauses and cross-checked against `ds.lark`: both [LTSL.5.2] cache-seed spellings (`ds.lark` has one), and not the two `draft` clauses (`exactly N`, `exclusive`). `dsc.build` still maps a test to the keyword-and-position `ad_test` it made when the block was skipped, so `compile` is unchanged. |
| **Literal spellings are lost.** `ex_int(int)` and `ex_float(float)` keep the value: `0x1F`, `1_000` and `1e3` come back as `31`, `1000` and `1000.0`. | `dsc.expr` | The source text beside the value (`raw`), per §6. `dump-ast` reads it off the literal's token span, so the CST does not change. |
| **Strings are unstructured.** `ex_string` holds the literal's raw content: escapes undecoded, `{...}` interpolation sites unparsed (that is a second pass, [LLEX.13.2.1]). | `dsc.expr` | **Done in A6.** Python's f-string model: a `Constant` with the decoded value, or a `JoinedStr` of decoded `Constant` runs and `FormattedValue` sites. `dump-ast` reads them with `dsc.strlit`, which validation and lowering now share; before it there were five site scanners that disagreed. `unparse` writes `raw` back while the node still says what it said when parsed, and encodes from the value otherwise. Docstrings and unit labels stay raw content. |
| **Blank lines are discarded** with all other layout. | `dsc.lex` | A blank-line count beside each line's tokens, per §6; layout still ignores it. |

## 3. One schema, generating both sides

CPython defines every node once, in `Parser/Python.asdl`, and generates the C
structs and the Python classes from it. `ds_ast` does the same:

- **`tools/ds_ast/ds.asdl`**: every node type, its fields, their
  cardinality (`?`, `*`) and the location attributes, in ASDL, which a Python
  `ast` user can already read.
- **Generated from it, never hand-written** ([STYL.5.9.6]'s rule for
  registries, applied to a tool), by `gendsast.py` beside it:
  - the Python node classes, `ds_ast/_nodes.py`;
  - dsdb's JavaScript table, `tools/dsdb/lib/ast/nodes.js`: every constructor's
    fields and attributes, with a JSDoc type for each, for `ds lsp`.
    `tools/dsdb/lib/ast/read.js` reads `dump-ast`'s JSON against it as strictly as
    `from_json` does.
- **The Mercury side maps CST to schema by hand**, in one module
  (`dsc.astjson`), names included. A new CST constructor makes that module's
  switch non-exhaustive, which is a compile error, so the mapping cannot fall
  behind the grammar silently. A renamed field is caught by the strict
  readers, which refuse a key `ds.asdl` does not have and a field it has
  that was not written.
- The generator's check fails when either generated file is stale, and
  `tests/test_nodes.py` runs the same check in the `ds-ast` gate.

The schema describes the **source surface**, not the CST's Mercury types. Its
names are Python-`ast`-flavoured (`Module`, `Schema`, `Slot`, `Rule`,
`Pattern`, `Emit`, `Call`, `BinOp`, `Compare`, `Name`, `Constant`), because
that is the familiarity the requirements ask for, and a CST constructor such as
`lgra_5_1_schema_decl` is a clause citation, not a user-facing name.

## 4. The Python API

Every name below is the one Python's `ast` uses, with the same meaning.

| | |
|---|---|
| `parse(source, filename="<unknown>", *, dsc=None)` -> `Module` | runs `dsc dump-ast - --filename <filename>` with the source on standard input (no temporary file), reads the JSON, builds nodes. **The compiler is the only parser** ([LTSL.1.2]); `ds_ast` contains none. The binary is `dsc=`, else `$DS_AST_DSC`, else `$DS_MERCURY_DSC`, else `dsc` on `PATH` |
| `from_json(obj)` | the reader `parse` uses, for a dump already in hand. **Strict**: an unknown `_type`, an unknown or missing key, or a value of the wrong kind raises `DSTreeError` -- that is what makes the Mercury writer's names checkable against `ds.asdl` |
| `dump(node, indent=None, include_attributes=False)` | as Python's |
| `unparse(node, *, line_map=False)` -> `str` | DS source, comments written back where they were. With `line_map=True`, `(source, lines)`: `lines[i]` is the tuple of nodes line `i + 1` was written for, outermost first. Python has no such option; a program built as nodes needs it, because `dsc` can only name lines of this text |
| `walk`, `iter_fields`, `iter_child_nodes`, `get_docstring` | as Python's |
| `NodeVisitor`, `NodeTransformer` | as Python's, `generic_visit` included |
| `copy_location`, `fix_missing_locations`, `increment_lineno` | as Python's |
| `AST` base class, `_fields`, `_attributes`, `lineno`, `col_offset`, `end_lineno`, `end_col_offset` | as Python's. Columns are code points, as `dsc`'s are, not UTF-8 bytes as CPython's are, and the docstring says so |
| `compile(node, filename="<unknown>", *, dsc=None, search_path=(), dialect_files=())` -> `bytes` | `unparse`, then `dsc compile --diagnostics json`; returns the `.dsc`. Each diagnostic in the program's own text is reported at the deepest node on its line that has a `lineno`, under `filename`, so a generator's nodes are refused at the lines it took them from. A diagnostic in another file the compile reads, a library it imports, keeps the file, line and column `dsc` named ([RCLI.1.9]), with no node. Named after the builtin, so it is not in `__all__`: a star import must not shadow it |

A parse error raises `SyntaxError`-shaped `DSSyntaxError` with `filename`,
`lineno`, `offset` and the `dsc` diagnostic code. `compile` raises it for the
first error of a refusal, with `node`, `generated` (where `dsc` put it in the
text) and every diagnostic on `diagnostics`, and issues an accepted program's
warnings as `DSSyntaxWarning`, through `warnings`, as Python's `compile`
issues `SyntaxWarning`.

**Comments.** Each node carries `comments_before` and `comment_after`
(leading full-line comments, and a trailing same-line comment). A comment
with no node to attach to (end of file, end of a block) goes on the enclosing
block's `comments_end`. This is `libcst`'s approach reduced to what DS's
line-structured grammar needs.

## 5. How it is verified

- **Round trip, over the whole corpus**: for every `.ds` / `.dstest` in
  `specs/conformance/**`, `runtime/mercury/test/fixtures/**`, and the
  staged programs of `benchcc --program`:
  - `parse(unparse(parse(s))) == parse(s)` (structural equality, locations
    excluded);
  - every comment in `s` appears in `unparse(parse(s))`, in order.
- **Compile equivalence**: `dsc compile` of `s` and of `unparse(parse(s))`
  produce the same diagnostic code set and the same terminal ordinals.
- **Schema drift**: `gen_ds_ast.py --check`, and the Mercury build.
- A new lane, `ds-ast`, runs all three. Measuring before it blocks, like every
  lane added this cycle.

## 6. Settled beyond Python

1. **Literal spellings are kept.** Every literal node carries `raw`, its
   source text, beside its value. `unparse` writes `raw` when it still denotes
   `value`, and a spelling of `value` otherwise, so a transform that does not
   touch a literal writes it back as the author wrote it, and one that changes
   the value is never contradicted by a stale spelling.
2. **Blank lines are kept.** Every declaration and statement carries
   `blank_lines_before`, the count of blank lines between it and what precedes
   it, and `unparse` restores them. A rewritten buildfile keeps its sections.

With comments, these make `unparse(parse(s))` equal to `s` up to whitespace
inside a line, which is stronger than Python can state. The round-trip lane
(§5) checks that too.

## 7. Order of work

Each rung lands green on its own.

| Rung | What | Checked by |
|---|---|---|
| A1 | `dsc.lex` returns comments and blank-line counts on a side channel; layout unchanged | `mercury-dsc` (tests: a comment on every kind of line; blank runs; bidi check unchanged; every existing layout test unchanged) |
| A2 | `ds.asdl`, `gen_ds_ast.py`, the generated `_nodes.py` | the generator's `--check`; unit tests of the classes |
| A3 | `dsc dump-ast` and `dsc.astjson`: lex, layout and parse only (as `ast.parse` does no more), comments and blank lines attached, the five spans parsed to expressions, literals with `raw` | `mercury-dsc` (every corpus file dumps; the JSON validates against the schema) |
| A4 | `ds_ast.parse`, `dump`, `walk`, visitors, locations | the package's tests |
| A5 | `unparse` with comments, and the round-trip lane | `ds-ast` |
| A6 | the §2 gaps left after A3: strings as `JoinedStr` / `FormattedValue` with decoded values, and `test` declarations built | `mercury-dsc`, `ds-ast` |
| A7 | the `ds_ast` wheel in the release | `fleet` |

Then the consumers move.

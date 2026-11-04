<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Spec-authoring style

How the DS specification is written. Scope is `[STYL.3]`.

## Normative vocabulary [STYL.1]

### The fixed vocabulary [STYL.1.1]

| Term | Role | Example |
|---|---|---|
| `must` / `must not` | Contractual requirement. Violation = non-conforming. | "The engine must suppress no-op reassertions." |
| `may` | Permitted freedom. The implementer chooses. | "The runtime may execute activations in parallel." |
| `should` / `should not` | Recommended; deviation is allowed with reason. | "Adapters should suppress no-op updates at the source." |
| `does` / `is` | Observable behaviour; a consequence of some `must`. | "The engine does not reassert a fact whose values are unchanged." |
| `will` | Behaviour that is deferred. | "v1.1 will add cross-tier logical coalescence." |
| (plain prose) | Rationale, discussion. No weight word. | "This keeps the fact graph acyclic." |

The list is closed.

### Rules [STYL.1.2]

1. Every normative claim uses exactly one of `must`, `must not`, `may`,
   `should`, `should not`.
2. Every `does` / `is` claim traces to a `must` somewhere in the corpus.
3. `will` appears only in deferred content.
4. The actor is named: the engine, the compiler, the runtime, the adapter, the
   author. No passive voice in a normative passage.
5. These words do not appear in a normative passage: `typically`, `generally`,
   `usually`, `often`, `tends to`, `in most cases`, `should probably`,
   `we recommend`, `it is suggested`.

---

## Numbering [STYL.2]

### ID shape [STYL.2.1]

`[PFX.N]`, `[PFX.N.M]`, `[PFX.N.M.K]`, `[PFX.N.M.K.J]`: up to four levels,
following the document's section structure. A segment is digits with an
optional lowercase tail (`[0-9]+[a-z]*`), so `RDSC.5a` and `RBND.4b.2` are
well formed. The pattern in `specs/clause.schema.json` is the authority.

### Prefix table [STYL.2.2]

Every normative document has a fixed 4-letter prefix. Its first letter names
its tree: `L` the language, `R` the runtime specification, `I` the reference
implementation (libds), `N` the integrator-facing contract. A struck-through
row is a retired document; its prefix and ids are never reused.

**Language** (`specs/language/`):

| Doc | Prefix |
|---|---|
| SCOPE.md | `LSCO` |
| GRAMMAR.md | `LGRA` |
| LEXER.md | `LLEX` |
| FACT_MODEL.md | `LFAC` |
| LOGICAL_FACTS.md | `LLOG` |
| EXPRESSIONS.md | `LEXP` |
| NULL.md | `LNUL` |
| SERIES.md | `LSER` |
| SERIES_SIGNAL.md | `LSIG` |
| STORAGE.md | `LSTO` |
| ~~PROBABILITY.md~~ — removed v1, reserved v2 | `LPRB` |
| HYDRATION.md | `LHYD` |
| CALL_RESPONSE.md | `LCRS` |
| CALL_CONTINUATION.md | `LCCO` |
| ERROR_CODES.md | `LECC` |
| TIMED_ACTIONS.md | `LTAC` |
| STRINGS.md | `LSTR` |
| REGEX.md | `LREG` |
| TIME.md | `LTIM` |
| INTERVAL.md | `LINT` |
| SCHEMA_SCOPES.md | `LSCP` |
| RESTART.md | `LRST` |
| COMPILER_REPORT.md | `LCMP` |
| ADAPTER_CONTRACT.md | `LADP` |
| FACT_STREAM.md | `LFST` |
| DETERMINISM.md | `LDET` |
| TESTING.md | `LTES` |
| DEBUGGING.md | `LDEB` |
| ERRORS.md | `LERR` |
| FORM_CATALOG.md | `LFCA` |
| LANGUAGE_SURFACE.md | `LLSU` |
| LET_BINDINGS.md | `LLET` |
| RULE_COOLDOWN_AND_DEBOUNCE.md | `LCDB` |
| THEN_TEMPORAL_SEQUENCE.md | `LTHE` |
| CYCLE_DETECTION.md | `LCYC` |
| CONFORMANCE.md | `LCON` |
| DIALECTS.md | `LDIA` |
| TIERING.md | `LTIE` |
| UNIT_SYSTEM.md | `LUNI` |
| DYNAMIC_TTL.md | `LDTL` |
| ~~BITEXACT.md~~ — removed v1, reserved v2 | `LBEX` |
| ~~CONNECTIONS.md~~ — retired entire | `LCNN` |
| CONSTSPACE.md | `LCSP` |
| EXTENSION_CAPABILITIES.md | `LCAP` |
| IMPORTS.md | `LIMP` |
| NOLINSCAN.md | `LNLS` |
| NOLOGICAL.md | `LNOG` |
| NOREGEX.md | `LNRE` |
| SERIES_SAMPLE.md | `LSMP` |
| OPAQUE_TYPES.md | `LOPQ` |
| TEST_LANGUAGE.md | `LTSL` |
| IDENTIFIERS.md | `LNAM` |
| CONVERSIONS.md | `LCST` |
| CONTAINERS.md | `LCNT` |

**Runtime** (`specs/runtime/`):

| Doc | Prefix |
|---|---|
| ARCHITECTURE.md | `RARC` |
| LOWERING.md | `RLOW` |
| HYDRATION_IMPLEMENTATION.md | `RHIM` |
| ~~PROBABILITY_IMPLEMENTATION.md~~ — removed v1, reserved v2 | `RPRB` |
| ~~DEBUG_PROTOCOL.md~~ — folded into `integration/`; see `NDBG` | `RDBG` |
| TESTING_IMPLEMENTATION.md | `RTIM` |
| ~~METRICS.md~~ — moved to `integration/`; see `NMET` | `RMET` |
| ~~TIER_DIALECTS.md~~ — retired entire | `RTDI` |
| CONFORMANCE_TESTS.md | `RCTS` |
| DSC_FORMAT.md | `RDSC` |
| COMPILER_CLI.md | `RCLI` |
| ~~DS_PROTOCOL.md~~ — retired entire | `RDSP` |
| CODE_AOT.md | `RAOT` |
| ~~CONNECTIONS.md~~ — retired entire | `RCNN` |
| DIALECT_BINDING.md | `RBND` |
| FACT_STREAM.md | `RFCS` |
| ~~PORTABLE_IR.md~~ — retired entire | `RPIR` |
| REALTIME_CONTRACT.md | `RTCT` |
| ~~WIRE.md~~ — retired entire | `RWIR` |
| ~~CALL_IMPLEMENTATION.md~~ — retired entire | `RCIM` |
| ~~CALL_TARGETS.md~~ — retired entire | `RCTG` |

**Implementation** (`specs/impl/`):

| Doc | Prefix |
|---|---|
| ALLOCATOR.md | `IALC` |
| ARCHITECTURE.md | `IARC` |
| DATA_MODEL.md | `IDAT` |
| ~~PROBABILITY.md~~ — removed v1, reserved v2 | `IPRB` |
| ERRORS.md | `IERR` |
| TESTING.md | `ITST` |
| ~~COMPILER.md~~ — retired entire | `ICOM` |
| DISPATCHER.md | `IDSP` |
| IRET.md | `IRET` |
| SPEC_TESTING.md | `ISTS` |
| CODE_AOT.md | `IAOT` |
| SERIES_BACKINGS.md | `ISBK` |

**Integration** (`specs/integration/`):

| Doc | Prefix |
|---|---|
| GETTING_STARTED.md | `NGST` |
| LIFECYCLE.md | `NLFC` |
| CALLBACKS.md | `NCBK` |
| ~~CONNECTIONS.md~~ — retired entire | `NCNN` |
| DETERMINISM.md | `NDET` |
| DIALECTS.md | `NDLC` |
| REALTIME.md | `NRTM` |
| SERIES_BACKENDS.md | `NSBK` |
| FACTS.md | `NFCT` |
| ERRORS.md | `NERR` |
| STORAGE.md | `NSTG` |
| ADAPTERS.md | `NADP` |
| TESTING.md | `NTST` |
| INTROSPECTION.md | `NDBG` |
| METRICS.md | `NMET` |
| ~~TRANSPORT.md~~ — never written | `NTRN` |

**Reserved letter `T`.** `T` prefixes are allocated outside this repository,
for `dsi`'s transport specifications. No `T*` document is
written here. DS has no wire protocol.

**`STYL`** is this document's own prefix. It owns no clause file.

### Placement [STYL.2.5]

A clause's `text` opens with its own id in brackets: `[LFAC.3.2.5] The engine
must …`. A heading carries its id at the end: `### Enforcement [LFAC.3.2]`.

### What gets an ID [STYL.2.6]

Every paragraph carrying one spec beat, every section heading, every block or
table carrying its own content (one id per table), and nothing else. A
document's preamble carries none (`[STYL.5.4]`); rationale for a numbered
item is part of that item.

### Stability rules [STYL.2.8]

1. [STYL.2.8.1] **Every ID is permanent.** It never refers to a different item.
2. [STYL.2.8.2] **Insertion appends.** A new item takes `max + 1` in its parent's
   scope, counted over the filenames in `specs/<tree>/<DOC>/`, tombstones
   included. It never fills a hole.
3. [STYL.2.8.3] **Deletion retires.** The clause file becomes a tombstone
   (`[STYL.5.1.4]`). The number is never reused.
4. [STYL.2.8.4] **Every gap is a tombstone.** A number missing from a scope's
   range carries a tombstone stub.
5. [STYL.2.8.5] **Physical order is not numeric order.** `seq` orders a
   document; ids reflect creation.
6. [STYL.2.8.6] **Moving an item keeps its ID.** Only its `seq` changes;
   its file, id and `parent` stay.
7. [STYL.2.8.7] **Every registry allocation is append-only.** Atom magics,
   protobuf field and enum numbers, error codes, `DS_VALIDATE_*` codes and every
   other number the corpus allocates follow the rules above: once retired, an
   allocation is reserved and never reused. An allocation binds at merge.

### Cross-references [STYL.2.10]

A clause cites a clause by its id, `[LFAC.3.2.5]`, and a protobuf message by
path, `proto/alfa.proto#AlphaNode` (`[STYL.2.14.3]`).

### Summary sections cite what they summarise [STYL.2.10a]

A clause in a section that restates other clauses — a commitments section, a
summary — must cite each clause it restates. A gate checks that every clause in
such a section carries at least one `refs` edge and that every edge resolves to
a live clause. Where the body and the summary disagree, the body is right.

A summary clause that restates a body clause, and that nothing depends on, is a
tombstone rather than a copy kept in step. A summary clause that something
depends on stays: a compiler or runtime tag, a formal tie, a conformance vector
named for it or linking it, or another clause's citation. Where it and a body
clause say the same thing, the body clause cites it rather than repeating it in
other words. A summary clause that states a rule no body clause states is not a
restatement, and stays.

### One home per rule, across documents [STYL.2.10b]

A rule has one home. A clause that restates a rule another document in its tree
states cites the owning clause by id instead (`[STYL.2.10]`). A link to a
document's path is not a citation: no `refs` edge follows from it. A restating
clause that nothing depends on is a tombstone. One that something depends on —
the dependents `[STYL.2.10a]` names — stays, cites the owner, and gives way to
it where the two disagree. Two clauses stating parallel rules about different
subjects are not a restatement, and both stay.

Whether two clauses state one rule is adjudicated, not detected. A gate checks
every pair the register `docs/_spec/spec_sql/styl_2_10b_register.tsv` rules a
restatement: unless one side is a tombstone, the restating clause cites the
owner or the owner's ancestor. It also checks that every id the register names
resolves. A pair reaches the register only when an adjudicator rules on it.

### Adding or retiring prefixes [STYL.2.11]

A new document takes a 4-letter prefix that collides with no row of
`[STYL.2.2]`, and gets a row. A retired document's row is struck through and
stays.

### The specs are sealed [STYL.2.12]

1. **A clause refers to no document outside `specs/`**, by a link, by a path or
   by naming it in prose.
2. **`specs/` holds normative material only.** `specs/conformance/` is the one
   exception (`[STYL.5.2.8]`).
3. **No file under `specs/` names the working record**, preambles included:
   no `PROPOSAL_*`, `NOTE_*`, `TRIAGE_*` or other working-record path.
   An owner ruling is written into the clause it governs, as what the clause
   states (`[STYL.2.17]`).

A clause that depends on an outside document is fixed by, in order: dropping a
decorative citation; absorbing the content the clause needs into an in-tree
clause; promoting the document into the tree under its own prefix, only if it is
a specification. A promoted document lands in the tree its prefix names
(`[STYL.5.2.2]`).

Exempt: a `checks` entry (`[STYL.5.3.6]`), which may name a file or element of
the formal layer, `proto/**` (`[STYL.2.14.1]`), and this document
(`[STYL.2.16]`). None of these is exempt from `[STYL.2.17]`, this document
aside.

The seal binds `specs/` only. It does not bind the changelog, the reference
books or the steering documents.

### The house-style doc is citable from a clause [STYL.2.16]

A clause may cite a `[STYL.N]` rule by id. It may not restate a STYL rule's
content as language. No other document outside `specs/` may be cited.

### Code in spec text [STYL.2.13]

**[STYL.2.13.1] `language/` and `runtime/` carry no code**: no code tokens, no C
symbols, no pointers into an implementation. A conforming runtime need not be
written in C.

**[STYL.2.13.1.1] No DS source samples, in any tree.** A block that *defines* —
a schema naming the slots of a fact the engine asserts — is a table
(`[STYL.5.3.2.1]`), not a sample, and stays.

**[STYL.2.13.2] C in `impl/` and `integration/`** is admissible only when it
adds clarity **and** deleting it leaves the clause's requirement intact. If the
requirement disappears with the code, the English is rewritten to carry it.

**[STYL.2.13.3] Symbolic names are suggestive; numbers and meanings are
normative.** An implementation must use the same numbers for the same meanings
and may name them as its language prefers.

**[STYL.2.13.4] Errors are defined in `language/`**, once. Every other tree,
and every C header, renders that table.

**[STYL.2.13.5] A tie to specific C means the clause is in the wrong tree.** A
`runtime/` clause that needs a C symbol belongs in `impl/` or `integration/`.
Formal-notation identifiers (a protobuf enum value such as `FN_NOW`) are not C
symbols.

**[STYL.2.13.6] An emitted-code feature splits.** `runtime/` states that the
capability exists and the artefact's format. `impl/` states what the reference
pipeline emits and how it builds it.

### Protobuf is a formal notation, and `proto/` is a specs directory [STYL.2.14]

**[STYL.2.14.1]** `proto/**` is part of the specification and inside the seal.

**[STYL.2.14.2]** Message names, field numbers, types, names and `reserved`
ranges are normative exactly as written.

**[STYL.2.14.3]** A `.proto` is cited by its path, a message by
`path#Message`. A stale path is a broken reference.

### Formal notations [STYL.2.15]

**[STYL.2.15.1] Where a registered notation applies, it is used instead of
English.**

**[STYL.2.15.2] The registered notations.** The list is closed.

| Notation | Written as | Use it for |
|---|---|---|
| **Mathematics** | LaTeX | formulae, bounds, complexity, algebraic relations |
| **EBNF** | a `.ebnf` file, cited by path | grammars — the language surface, token / atom streams, command lines (`[STYL.2.15.6.2]`) — and enumeration registries (`[STYL.2.15.6]`) |
| **Protobuf** | `.proto` under `proto/` (`[STYL.2.14]`) | portable data structures and wire messages — interchange only (`[STYL.5.9.7]`) |
| **Alloy** | a `.als` file under `formal/alloy/`, cited by path + name | invariants, relational constraints, closure over a set EBNF enumerates (`[STYL.2.15.7]`) |
| **RE2** | RE2 syntax, in `/pattern/flags` literals | every regular expression the language admits |
| **ASDL** | a `.asdl` file, cited by path + type or constructor | syntax trees a tool exchanges |
| **JSON Schema** | a `.schema.json` file, cited by path, + a `$defs` name or none | documents a tool writes |

`tools/ds_ast/ds.asdl` defines the tree `dsc dump-ast` writes, and
`compiler/dsc_diagnostics.schema.json` the diagnostics document. Each file is
the single source of what it defines (`[STYL.2.15.5]`), and its clause states
the residue: how the tree becomes JSON, what the document's order and exit code
are.

**[STYL.2.15.2.1] RE2 is the language's regular-expression syntax.** A clause
cites RE2 and states only what RE2 does not define.

**[STYL.2.15.2.2] PCRE and PCRE2 are excluded.** A clause offering a
backtracking engine as an option is a defect.

**[STYL.2.15.3]** A formal notation is not code; `[STYL.2.13.1]` does not
reach it. Every tree may use every registered notation.

**[STYL.2.15.4] Name the residue.** What a notation cannot express —
conditional cardinality, sortedness, permutation, topological order,
cross-token referential integrity — is stated in English once, in a clause
adjacent to it.

**[STYL.2.15.5] The notation is normative.** Where notation and prose disagree,
the notation wins. A clause restating what the notation says is removed.

**[STYL.2.15.5.1] Notation lives in a file, never in clause text.** A clause
cites its notation through a `checks` entry and does not restate it. A clause
whose notation has no file yet keeps its block until the file exists. Only a
tie gated in both directions — `alloy`, `tla`, `idris`, `k`, `saw`, `proto` —
licenses deleting the block; a conformance vector does not.

**[STYL.2.15.6] EBNF registers an enumeration; a terminal production is an
allocation.**

```
builtin_fn = FN_NOW | FN_ABS ;   (* the alternation is the closure *)
FN_NOW = "1" ;                   (* the production is the allocation *)
FN_ABS = "2" ;
FN_OLD = "7" ;                   (* retired: allocated, not a member *)
```

The alternation is the closed set. The number is stated, not annotated. A
retired production stays, binding its number to the name it held, and leaves
the alternation.

**[STYL.2.15.6.1] A registry generates every consumer.** Each registry ships
with a generator emitting every consumer's view of it (C and Mercury), as
`gen_ebnf_registry.py` does for `specs/registry/validate.ebnf`. Every output is
generated, never hand-written, and the reconciliation gate has one arm per
consumer.

**[STYL.2.15.6.2] A command line is a grammar.** A tool's command-line surface
is an EBNF file beside the tool, cited by path. Which options repeat, which are
required, which depend on others, and what each does to the artefact is the
residue (`[STYL.2.15.4]`), stated in clauses.

**[STYL.2.15.7] Alloy constrains what EBNF enumerates**: invariants, relational
properties, closure claims. An Alloy model carries content with the force of a
clause (`[STYL.2.15.5]`) and ties to clauses as a verification lane
(`[STYL.5.5.4]`).

### A spec states what is, not what was [STYL.2.17]

No file under `specs/` or `proto/` carries any of these, in any field or comment:
not a clause, its `checks` notes, a preamble, a `proto/**` comment, a schema's
descriptions, a registry, or anything under `specs/conformance/`:

- a date;
- an issue or pull request number;
- a reference to the owner, to an owner ruling, or to who ruled on anything;
- the name of a working-record item;
- what a clause used to say, or when it changed;
- what a retired number or name used to mean, or why it was retired;
- when something arrived;
- what was considered and refused;
- who found something, and how.

The state of an allocation is current, not history: a `reserved` statement, a
tombstone stub (`[STYL.5.1.4]`), and a registry's row or production for a number
out of use (`[STYL.2.15.6]`) stay, and say only that it is out of use.

A deprecated vector's `deprecated` reason (`[RCTS.1.2.12]`) stays. It states, in
the present tense, why the vector does not apply now (what the corpus reserves
or refuses, and which vector covers the case), and not what it used to pin or
when that changed.

A value a clause or a test is about is not one of these: a date a vector
asserts, or a row number in a table. A limit on what a check proves is stated as
what holds now, not by naming the issue that will lift it.

A clause is amended to state the new contract and nothing else. The history, and
the ruling and issue behind a clause, are in the commit message.

`reports/styl_2_17_marks.sql` lists every candidate for these and for
`[STYL.2.12]`'s, over all of those files. A row is read, not obeyed: the pattern
cannot tell a row number from an issue number. The gate `styl_2_17_no_marks` fails
on the forms no prose has a reason to carry: a tracker reference or a `#N` of three
digits or more, a working-record name, a ruling named as one, a full date in a
clause not about one or in the harness, and a path to a document. A date in a
vector is a value the vector is about, or history only reading finds.

Whether a sentence tells history is adjudicated, not detected. A gate matches a
broad pattern of history wording ("no longer", "previously", "removed in",
"formerly", …) in every clause and preamble, and fails on each hit the register
`docs/_spec/spec_sql/styl_2_17_register.tsv` does not hold. A hit reaches the
register only when an adjudicator rules it present tense ("a fact no longer
live"); one that tells history is fixed in the clause. History worded outside
the pattern passes the gate, and only reading finds it.

### A spec states what DS is, not what it lacks [STYL.2.18]

A clause describes what DS is and does. It does not list what DS does not have:
what no clause specifies is not in DS, and a list of absences has no end.

A negative that binds stays: a `must not`, a construct the compiler or runtime
must refuse, and a reserved allocation ([STYL.2.17]). So does a preamble's
statement of what its document does not cover ([STYL.5.4.1]).

---

## Scope [STYL.3]

- Every clause under `specs/language/`, `specs/runtime/`, `specs/impl/` and
  `specs/integration/`, and each document's `_file.json` preamble.
- `proto/**`, with `[STYL.2]`'s numbering replaced by path identity
  (`[STYL.2.14.3]`).
- For `[STYL.2.12]` and `[STYL.2.17]`, every other file under `specs/`.
- Not `docs/future/`.

---

## Structured spec format [STYL.5]

### Source of truth [STYL.5.1]

[STYL.5.1.1] **The JSON is the specification.** Each clause is one JSON file
under `specs/`. The Markdown books are generated from it (`[STYL.5.6]`) and
never edited.

[STYL.5.1.3] **A clause exists iff its JSON file exists.** Every tool reads the
JSON, never the rendered Markdown.

[STYL.5.1.4] **A retired ID is a tombstone stub**: `kind: "tombstone"`, empty
`text`. It does not render, and every `parent` and `refs` naming it still
resolves. An id co-defined in another clause's header (`also_ids`) is not a
tombstone.

### Directory layout [STYL.5.2]

[STYL.5.2.1] One directory per document, one file per clause:

```
specs/
  clause.schema.json                  ← a clause file (STYL.5.3)
  file.schema.json                    ← a _file.json manifest (STYL.5.4)
  language/
    FACT_MODEL/
      _file.json
      LFAC.1.json
      LFAC.1.7.json
      ...
  runtime/  impl/  integration/
  registry/                           ← EBNF enumeration registries (STYL.5.2.7)
  conformance/                        ← the conformance corpus and harness (STYL.5.2.8)

proto/                                ← normative (STYL.2.14); not under specs/
```

[STYL.5.2.2] **The tree comes from the prefix**: `L` → `language`, `R` →
`runtime`, `I` → `impl`, `N` → `integration`. It is not stored.

[STYL.5.2.3] **The document directory** is the document's basename without
extension (`DSC_FORMAT/`). Its `_file.json` records the prefix.

[STYL.5.2.4] **The filename is the ID** (`RDSC.4a.6.json`). Render order comes
from `seq`, never from the filename.

[STYL.5.2.5] **`proto/` sits at the repository root**, because the build reads
it. It has no prefix, no dotted ids and no `_file.json`.

[STYL.5.2.6] **Moving a `.proto` renames it**, and every citation is updated
with it.

[STYL.5.2.7] **`specs/registry/` holds the EBNF enumeration registries**
(`[STYL.2.15.6]`). A registry is cited by path; moving one renames it. A grammar
that is not an enumeration does not go here (`[STYL.2.15.6.2]`).

[STYL.5.2.8] **`specs/conformance/` holds the conformance corpus and the
harness that runs it.** Nothing in it is a clause: schema validation, the
relational load and the book renderer do not read it. A vector is cited by path.
The harness is the one piece of code admitted under `specs/`; no other tool is.

### Per-clause file schema [STYL.5.3]

`specs/clause.schema.json` is the authoritative shape and forbids unknown keys.

[STYL.5.3.1] **Identity fields.**

| Field | Type | Req | Meaning |
|---|---|---|---|
| `id` | string | ✔ | Canonical clause ID; equals the filename stem (`[STYL.2.1]`). |
| `prefix` | string | ✔ | `id` up to the first dot. |
| `doc` | string | ✔ | Source document basename (`DSC_FORMAT.md`); equals the parent directory. |
| `parent` | string \| null | ✔ | Enclosing clause ID; `null` for a top-level item. |
| `seq` | integer | ✔ | Order within the document (`[STYL.2.8.5]`). |
| `depth` | integer | ✔ | ID level 1–4. |

[STYL.5.3.2] **Content fields.**

| Field | Type | Req | Meaning |
|---|---|---|---|
| `kind` | enum | ✔ | See the table below. |
| `heading` | string \| null | ✔ | Section title for a heading or a titled item; else `null`. |
| `text` | string | ✔ | The item's Markdown body. |

| `kind` | Check expected (`[STYL.5.5.3]`) |
|---|---|
| `normative` | yes (or a recorded `gap`) |
| `definition` | usually |
| `observation` | often |
| `grammar` | via conformance parse tests |
| `table` | as its rows require |
| `note` | no |
| `heading` | no |
| `tombstone` | no (`[STYL.5.1.4]`) |

The first five have a ratification state (`[STYL.5.3.11]`).

[STYL.5.3.2.1] **A registry table carries `data`, not `text`.** A table a tool
consumes stores `{"columns": [...], "rows": [[...], ...]}` (or `{"ebnf": "..."}`
for a grammar block) in `data`, and its `text` is empty. The book renders it
from `data`. A presentation table stays Markdown in `text` and has no `data`.
Prose explaining a registry table is a sibling clause.

[STYL.5.3.3] **One lifecycle field: `deferred`.**

| Field | Type | Req | Meaning |
|---|---|---|---|
| `deferred` | boolean | | Written only as `true`: the obligation does not bind this edition. Absent, it binds. |

No field records whether a clause is ratified; that is derived
(`[STYL.5.3.11]`). No field records a version. A retired clause is a tombstone.

[STYL.5.3.3.2] **`deferred` is about the obligation, not about the code.** A
built, working mechanism with no obligation in this edition is `deferred`.
Whether an implementation honours a clause is its ratification.

[STYL.5.3.4] **Relationship fields.**

| Field | Type | Meaning |
|---|---|---|
| `refs` | string[] | Clause IDs cited by `text`, extracted from its `[ID]` tokens. |
| `referenced_by` | string[] | Inverse of `refs`; generated. |
| `also_ids` | string[] | IDs co-defined in this clause's header. |

[STYL.5.3.5] **Mention fields.** Identifiers the clause's prose touches, for
search.

| Field | Type | Meaning |
|---|---|---|
| `errors` | string[] | Error codes (`DS_ERR_WM_FULL`). |
| `metrics` | string[] | Metric names. |
| `atoms` | string[] | DSC atom magics (`ALFA`, `BETA`). |
| `symbols` | string[] | Builtins, entry points, enum values (`FN_NOW`). |
| `keywords` | string[] | Free tags. |

[STYL.5.3.5.1] **`defines` marks the single authoritative definer** of a
registry identifier, keyed by registry:
`"defines": {"atoms": ["ALFA"], "errors": ["DS_ERR_WM_FULL"]}`. The
registry-sync gate (`[STYL.5.9]`) reads `defines` and never the mention fields.
Each registry identifier has exactly one defining clause.

[STYL.5.3.6] **The `checks` block** maps a verification tool to an array of
check objects. Tools: `alloy`, `tla`, `saw`, `k`, `cbmc`, `souffle`, `proto`,
`idris`, `ebnf`, `asdl`, `jsonschema`. `alloy`, `tla` and `idris` tie by `path`
+ `name`; `k`, `saw` and `souffle` by `path`; `proto` by path + message; `ebnf`
by path + production; `asdl` by path + type or constructor; `jsonschema` by path
+ `$defs` name, or by path alone (`name: null`) for the whole document. `ebnf`,
`asdl` and `jsonschema` are hand-authored and tie one way, clause to file: the
file carries no back-tag.

| Field | Type | Req | Meaning |
|---|---|---|---|
| `path` | string | ✔ | Repo-relative file. Must exist. |
| `name` | string \| null | ✔ | The element in the file; `null` only for a file-level tie. |
| `tag` | enum | ✔ | `spec` (formalizes the clause) · `derives` (proves a consequence) · `gap` (a known missing check; `note` required). |
| `polarity` | enum \| null | | `positive` · `negative` · `differential`. |
| `note` | string \| null | | Required when `tag` is `gap`. |

```jsonc
"checks": {
  "k":     [ { "path": "formal/k/rgate.k", "name": "rgate.comb_fire", "tag": "spec" } ],
  "proto": [ { "path": "proto/beta.proto", "name": "BetaNode", "tag": "spec" } ]
}
```

[STYL.5.3.6.1] **A `cbmc` tie is one-directional.** The clause names the
harness and its entry point and the tie is resolved clause → harness. Harnesses
carry no back-tag, so nothing checks harness → clause.

[STYL.5.3.6.2] **A model tie may state what the model concluded.**
`checks.alloy`, `checks.tla` and `checks.idris` entries may carry a `verdict`:

| `verdict` | Meaning | Tools |
|---|---|---|
| `proven` | The element establishes the clause, within a bounded model's scope. | all three |
| `refuted` | The clause is false. `counterexample` is required, and the clause carries `verification: "refuted"`. | all three |
| `violated` | The clause stands and the model shows an implementation breaking it. `counterexample` is required; `verification` is untouched. | all three |
| `partial` | The element and the clause do not coincide, in either direction. `note` says how. | all three |
| `assumed` | The element rests on a `postulate` / `believe_me` / `assert_total` / `assert_smaller`. | `idris` only |

An `idris` entry also carries a `role`:

| `role` | Meaning | `verdict` |
|---|---|---|
| `definition` | Models the clause's vocabulary. | optional |
| `lemma` | A step toward a theorem. | optional |
| `theorem` | States and discharges a claim of the clause over its inputs. | required |
| `witness` | A concrete instance or refutation. | required |

`assumed` is recorded on every role whose element rests on a hole. A clause
with a refuting tie carries `verification: "refuted"`, and a clause carrying it
has a refuting tie.

**[STYL.5.3.6.3] A conformance test is linked from the test.** A test checks a
clause when it names it:

- **by name** — a vector whose file name leads with the clause id
  (`specs/conformance/runtime/LSTO.4.7.5_refused_cache_write_stops_the_rhs.json`),
  or a test function named `test_<id, dots as underscores, lower-cased>__<tag>`;
- **by a linking comment** — an `@spec [ID]` comment on the line above the test,
  naming one or more clauses; in a vector, its top-level `clauses` list.

A test with no link is a unit test. No clause stores the link; the spec gate
reads it from the tests on every load (`scripts/spec/test_links.py`).

**[STYL.5.3.6.4] A vector may name the formal witnesses it runs.** A vector's
top-level `witnesses` list names each `checks` entry whose scenario the vector
runs, as `<path>#<name>`. Each entry must name an entry whose `role` is
`witness` ([STYL.5.3.6.2]), on a clause the vector links ([STYL.5.3.6.3]). The
`ties` gate `styl_5_3_6_4_vector_witnesses` checks this. That the vector's steps
and expected outcome are the witness's scenario, only reading can check, and the
formal lane reviews each new pairing.

A witness-linked vector counts toward ratification as any linked test does, and
no more. `reports/witness_vector_coverage.sql` lists the witnesses no vector runs
yet.

[STYL.5.3.7] **Coverage field.**

| Field | Type | Meaning |
|---|---|---|
| `verification` | enum \| null | `covered` · `partial` · `gap` · `exempt` · `refuted`. Derived, except `gap` with its reason and `refuted` (`[STYL.5.3.6.2]`), which are asserted. |
| `gap_reason` | string \| null | Required when `verification` is `gap`. |

[STYL.5.3.9] **Required fields** are `id`, `prefix`, `doc`, `parent`, `seq`,
`depth`, `kind`, `heading` and `text`. Every other field is optional and is
omitted rather than written empty.

[STYL.5.3.11] **A clause is ratified iff it is not deferred and at least one
linked conformance test counts for it.** Only the five kinds that expect a check
have a ratification state. A linked test (`[STYL.5.3.6.3]`) counts when all of
these hold:

1. **Per-PR CI runs it.**
2. **It passes on every official product of its class, with the same
   results.** The harness that runs a test decides its class:

   | Class | Products | Covers clauses in |
   |---|---|---|
   | compiler | the compiler | L, R |
   | runtime | libds, the Mercury runtime | L, R |
   | C API | libds | N, I |
   | binding | pyds, @ds-lang/ds, mercury_ds | N |
   | tooling | dsdb | N |

   A test run on fewer products than its class has does not count, nor does
   one whose outcome on a product is anything but a pass, nor a scenario pinned
   as an expected difference.
3. **The clause is in a tree its class covers.**
4. **The test observes what the clause states.** A vector whose expectation is
   `compile_ok` observes that its program compiles, and the warning it names if
   it names one, and nothing the program does. It counts only for a `grammar`
   clause and for a clause marked `compiler_only` ([STYL.5.3.11.1]).

`scripts/spec/test_links.py` maps each test directory to its harness and
products. The spec gate's `reports/ratification.sql` gives the counts per prefix
and, for each link that does not count, the reason.

[STYL.5.3.11.1] **`compiler_only` marks a clause the compiler's verdict settles.**

| Field | Type | Req | Meaning |
|---|---|---|---|
| `compiler_only` | boolean | | Written only as `true`: everything the clause states is the compiler's verdict on a program. |

The compiler's verdict on a program is whether it accepts it, which diagnostics
it raises, and which names are in scope where. A clause stating anything else is
not `compiler_only`, even when the compiler also checks it: what a program does
when it runs, and what the compiler writes into the artefact or the analysis
report. Only a `normative`, `definition`, `observation` or `table` clause carries
the field. A `grammar` clause needs none.

### Per-document manifest [STYL.5.4]

[STYL.5.4.1] Each document directory holds a `_file.json` carrying the
document's preamble, which has no clause ids and states no status. Whether a
clause binds is its `deferred` field ([STYL.5.3.3]), and whether it is ratified
is derived ([STYL.5.3.11]); the book renders both. A preamble says what the
document covers and what it does not.

| Field | Type | Req | Meaning |
|---|---|---|---|
| `doc` | string | ✔ | Basename (`DSC_FORMAT.md`). |
| `tree` | enum | ✔ | `language` · `runtime` · `impl` · `integration`. |
| `prefixes` | string[] | ✔ | The prefix(es) the document owns. |
| `title` | string | ✔ | Human title. |
| `paired_with` | string[] | | Sibling documents. |
| `proto` | string[] | | Proto files the document's atoms and enums are defined in. |
| `summary` | string | | One-line synopsis. |
| `preamble` | string | | The document's opening Markdown, rendered before its first clause. |
| `src` | string | | The rendered page's path. |

### Validation [STYL.5.5]

[STYL.5.5.1] **Schema.** Every `*.json` under `specs/`, outside
`specs/conformance/`, validates against `specs/clause.schema.json`, or
`specs/file.schema.json` for a `_file.json`.

[STYL.5.5.2] **Reference integrity.** Every id in `parent` and `refs` resolves
to a clause file, a tombstone included; every `checks[*].path` resolves to a
file in the repository.

[STYL.5.5.3] **Coverage.** A clause of a check-expected kind with no `checks`
entry and no asserted `gap` is reported.

[STYL.5.5.4] **Model ties hold in both directions.** For every `checks` entry
on `alloy`, `tla` or `idris`, the named element carries a back-tag naming the
clause; every `//@spec [ID]` tag in a model file (`--@spec` in Idris) appears as
a `checks` entry on clause `[ID]`. An Idris element is named for its clause.
`k`, `saw` and `souffle` tie by `path`.

### Rendering [STYL.5.6]

[STYL.5.6.1] `scripts/spec/spec_book.py` renders `specs/**` to the book: per
document, clauses in `seq` order, headings as section headers, ids shown as
`[PFX.N.M]`, `refs` as links.

[STYL.5.6.2] **Rendered pages are not committed.** `docs/specs/.gitignore`
ignores every `.md` in the four tree directories except `README.md`, by
pattern. `docs/specs/` holds the book configuration, the table of contents, the
per-tree `README.md` chapters and the generated pages, and nothing else.

[STYL.5.6.4] **One page per `.proto`**: the protobuf source, rendered, anchored
on its path so `proto/alfa.proto#AlphaNode` resolves, and not committed. A page
withheld from an edition's book is named in `spec_book.py`'s unpublished set;
its clauses stay in the tree and stay gated.

### Registry-sync gate [STYL.5.9]

[STYL.5.9.1] **Every identifier the corpus allocates from a registry is
defined by exactly one clause, matches its allocation in code or proto, and is
append-only** (`[STYL.2.8.7]`).

[STYL.5.9.2] **Registries covered.**

| Registry | Spec side (`defines`) | Code / proto side | Invariant |
|---|---|---|---|
| DSC atom magics | `defines.atoms` | atom magic → field-number map; frozen atom census (RFCS.3.1) | one defining clause per magic; append-only; retired magics reserved |
| Error codes | `defines.errors` on the `[NERR]` census | `proto/status.proto` `DsStatus` ↔ `libds.h` `#define DS_ERR_*`; the bindings' renderings are generated from the proto | proto is the source; C defines no code the proto lacks, at the proto's value; census and C hold the same live set |
| Builtin op enum | `defines.symbols` (`FN_*`) | `proto/builtin_fn.proto` ↔ the `builtin_fn.h` C mirror | C ⊆ proto (proto keeps the tombstones); values stable |
| Proto field numbers | clause references | proto `reserved` ranges | append-only (protobuf `reserved` on deletion) |
| Fault causes | `defines.symbols` | `proto/engine_error.proto` `TrapKind`, `proto/engine_fault.proto` `EngineFault`, `proto/bounds_error.proto` `CapName` ↔ their `libds.h` C mirrors | proto is the source, C mirrors it exactly; `TrapKind` and `CapName` are closed sets, `EngineFault` is append-only |
| Capabilities | the `[LCAP.1]` registry | `proto/capabilities.proto` `Capability` ↔ its `libds.h` C mirror | proto is the source, C mirrors it exactly; append-only. Advisory until the C mirror lands (`[STYL.5.9.5]`) |
| Log severity | RLOW.7.7.1's `proto` tie | `proto/log_level.proto` `LogSeverity` ↔ `libds.h` `ds_log_level_t` | proto is the source, C mirrors it exactly, 0-based on both sides |
| Stream event kinds | NCBK.2.13's `proto` tie | `proto/stream_event_kind.proto` `StreamEventKind` ↔ `libds.h` `ds_stream_ev_kind_t` | proto is the source, C mirrors it exactly, 0-based with no `UNSPECIFIED`; a retired number is reserved on both sides |
| Series element type | NSBK.5.3's `proto` tie | `proto/series_backend_ring_buffer.proto` `SeriesElementType` ↔ libds's internal `series/backend.h` `ds_series_element_type_t` (`[ISBK.2.1]`) | proto is the source, C mirrors it exactly, `UNSPECIFIED` on both sides |
| Identity role | NFCT.1.4.5's `proto` tie | `proto/slot.proto` `IdentityRole` ↔ `libds.h` `ds_identity_role_t` | proto is the source, C mirrors it exactly, `UNSPECIFIED` on both sides |
| In-process vocabularies | the `ebnf` ties of NMET.3.4, NSBK.6.3, NSTG.2.4.3, NFCT.2.8, NFCT.2.9, NFCT.4.5, NLFC.5.6 and NLFC.10.4 | `specs/registry/metric_kind.ebnf`, `series_agg.ebnf`, `cache_removal_reason.ebnf`, `slot_type.ebnf`, `json_kind.ebnf`, `schema_lifecycle.ebnf`, `clock_mode.ebnf`, `admission.ebnf` ↔ their C mirrors: in `libds.h`, and for `series_agg.ebnf` in libds's internal `series/backend.h` (`[ISBK.1.1]`) | the registry is the source, C mirrors it name for name and value for value; a retired production is no C member |
| Value kinds | RFCS.23.2 | `proto/fact_external.proto` `Kind` ↔ `libds.h` `ds_kind_t` / `ds_slot_kind_t` / `ds_arg_kind_t` and Mercury's `ds.kind`, all generated by `gen_kind_registry.py` | proto is the source; each mirror holds exactly the members its subtype admits, at the proto's numbers; a subtype's number is reserved in the other subtypes' mirrors |

[STYL.5.9.3] **The check, per registry, in both directions.** The spec's
`defines` set and the code or proto allocation set must be equal; no
identifier has two defining clauses or two allocation sites; every retired
identifier is a tombstone on the spec side and reserved on the code side.

[STYL.5.9.5] **A registry is advisory until** its `defines` markers are on the
owning clauses and its code side exists, then enforcing.

[STYL.5.9.6] **Every row but Capabilities is enforcing**, as SQL gates under
`docs/_spec/spec_sql/gates/{reg-*,proto}/styl_5_9_2_*.sql`.

- **Atom magics.** The census (`[RDSC.7.1]` ∪ `[RFCS.3.1]`: live, deferred,
  retired) against `proto/atom.proto`'s `Atom.oneof body`. Code equals the live
  set; a deferred or retired magic is not allocated.
- **Error codes.** One source, `proto/status.proto`, which protoc holds to
  one value per code and no reuse of a `reserved` one. Two gates hold the
  rest: `styl_5_9_2_status_registry` holds `libds.h` to the proto by name and
  value, and `styl_5_9_2_error_codes` holds the census to `libds.h` by name,
  the identifier `defines.errors` carries. A code in the proto with no
  `#define` yet is work not done, not a violation. Retired codes are excluded
  from both sides. Each binding's rendering is generated from the proto and
  checked by its own lane's gate, so it needs no arm here
  ([STYL.2.15.6.1]).
- **Builtin op enum.** Only a C-only member or a value disagreement fails;
  proto ⊋ C is correct.
- **Proto field numbers.** Within each message and enum, no live field reuses a
  `reserved` number or name, and a `reserved` citing a clause cites a real one.
  A `oneof` shares its message's number space.

[STYL.5.9.7] **A public vocabulary has one definition and a checked mirror.**
An enumeration in `runtime/include/libds.h`, or any identifier set the public
surface exposes, is a registry under `[STYL.5.9.1]`: a row in `[STYL.5.9.2]`, a
reconciliation gate, and negative fixtures. It is never a bare integer with its
values in prose. The definition is protobuf when the values travel — a message
field, or read by something that did not write it — and an EBNF registry
(`[STYL.2.15.6]`) when they do not.

An internal C type that a clause requires to mirror a registry is held to it the
same way, and has its row: the series aggregation and element type, which libds
keeps beside its backend vtable (`[ISBK.1.1]`, `[ISBK.2.1]`). A registry whose
mirror has no C home in this edition has no row until it does:
`series_storage_mode.ebnf`, whose clause (`[NSTG.5.5.4]`) is deferred.

### The query substrate [STYL.5.10]

[STYL.5.10.1] **Corpus gates are SQL.** `scripts/private/spec/spec_db.py` loads
`specs/**.json` into DuckDB; each gate is a `.sql` file under
`docs/_spec/spec_sql/gates/<group>/`, and a returned row is a violation.
Informational queries live in `docs/_spec/spec_sql/reports/`.

[STYL.5.10.5] **A gate ships with negative fixtures** pinning both directions:
a case it must flag and each exemption that must keep it quiet. They run before
the corpus gates.

[STYL.5.10.6] **A new check lands as a report first.** It becomes a gate once
its population is understood. A check that finds existing debt gates on growth
against a recorded baseline.

[STYL.5.10.8] **A conformance vector names the code path it pins.** Its
`scenario` states which path the case drives and, where a surface has more than
one implementation site, which site. Where a vector cannot pin what its name
suggests, the scenario says so. This is enforced by review. Where review cannot
settle it, the answer is a permanent vector that fails when the path is not
taken.

---

## Worked example

`specs/runtime/DSC_FORMAT/RDSC.4a.6.json`:

```json
{
  "id": "RDSC.4a.6",
  "prefix": "RDSC",
  "doc": "DSC_FORMAT.md",
  "parent": "RDSC.4a",
  "seq": 440,
  "depth": 2,
  "kind": "heading",
  "heading": "ALFA atom",
  "text": "## ALFA atom [RDSC.4a.6]\n\nOne alpha (pattern-filter) node. Admits facts of `schema_name`\nthat pass all listed tests into the node's memory.\n\nProto: `proto/alfa.proto#AlphaNode`.\n\n...",
  "atoms": ["AlphaNode"],
  "checks": {
    "proto": [
      { "path": "proto/alfa.proto", "name": "AlphaNode", "tag": "spec" }
    ]
  }
}
```

`specs/runtime/DSC_FORMAT/_file.json`, preamble elided:

```json
{
  "doc": "DSC_FORMAT.md",
  "tree": "runtime",
  "src": "docs/specs/runtime/DSC_FORMAT.md",
  "prefixes": ["RDSC"],
  "title": "DSC compiled-artifact format",
  "preamble": "<!-- (c) 2025, 2026 Dan Finster ... -->\n\n# DSC compiled-artifact format\n\n...",
}
```

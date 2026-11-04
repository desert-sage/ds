<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Lexical structure

## Source encoding

Source files are UTF-8. The lexer refuses a file with an ill-formed sequence anywhere in it, a comment and a string literal included. A byte-order mark at the start of a file is stripped; at any other position it is a lexer error.

A non-ASCII character is permitted inside a string literal, a regex literal and a comment, in an [identifier](#identifiers) and in a [`TYPE_SYM`](#type_sym). Anywhere else it is a lexer error.

*(Spec: [LLEX.1.1], [LLEX.1.2], [LLEX.1.3], [LGRA.2.1.1])*

## Line endings

LF and CRLF are accepted and read as one end of line. A CR with no LF after it is a lexer error.

*(Spec: [LLEX.2.1], [LLEX.2.2], [LGRA.2.2.2])*

## Horizontal whitespace

Space (0x20) is the only horizontal whitespace. Tab, form feed, vertical tab and every other whitespace code point are lexer errors.

*(Spec: [LLEX.3.1], [LLEX.3.2], [LLEX.3.3], [LGRA.2.2.1])*

## Comments

**`comment ::= '#' <any-char-except-newline>*`**

A run of one or more `#` starts a comment, which runs to the end of the line. The count of `#` has no meaning.

The lexer strips comments, and the parser produces the same AST with or without them. An artefact's `DsSource` source atom carries them verbatim.

*(Spec: [LLEX.4], [LLEX.4.1], [LLEX.4.2], [LGRA.2.4.2], [LGRA.2.4.3])*

## Blank lines

A blank line holds only spaces, only a comment, or nothing. It emits no token and has no effect on indentation tracking.

*(Spec: [LLEX.5.1], [LLEX.5.2], [LLEX.5.3], [LGRA.2.2.3])*

## Indentation

Each level is exactly 4 spaces. The lexer keeps a stack of indent levels, starting at `[0]`, and compares it with the leading-space count of each non-blank line:

| Count against the stack top | Result |
|---|---|
| greater, by 4 × N | N levels pushed, N `INDENT` tokens |
| less | levels popped to a match, one `DEDENT` per level |
| less, with no level matching | lexer error, `inconsistent dedent` |
| equal | no token |
| not a multiple of 4 from the enclosing indent | lexer error, `inconsistent indentation` |

`INDENT` and `DEDENT` precede the first content token of the line. At end of file, one `DEDENT` is emitted per level above 0.

*(Spec: [LLEX.6.1], [LLEX.6.2], [LLEX.6.3], [LLEX.6.4], [LLEX.6.5], [LLEX.6.6.1], [LLEX.7.4], [LGRA.2.3.1])*

## Logical lines

`NEWLINE` follows the last content token of a non-blank line.

*(Spec: [LLEX.7.1], [LLEX.7.2], [LLEX.16.3])*

## Bracket continuation

Inside an unclosed `( )`, `[ ]` or `{ }`, the lexer emits no `NEWLINE`, `INDENT` or `DEDENT`, and any leading-space count is legal. This is the only line continuation.

A mismatched closer, a bracket unterminated at end of file, and an unpaired `{` or `}` outside a string are lexer errors.

*(Spec: [LLEX.7.3], [LLEX.7.5.1], [LLEX.7.5.3], [LLEX.7.5.4], [LLEX.7.5.5], [LLEX.7.5.6], [LLEX.17.3])*

## Tokens

The lexer emits the longest operator that starts at the current position, and no token depends on parser state: `*` is always multiplication and `.` followed by a name is always slot access.

| Kind | Tokens |
|---|---|
| Single-character | `+` `-` `*` `/` `%` `&` `\|` `^` `~` `<` `>` `=` `(` `)` `[` `]` `{` `}` `,` `.` `:` `@` `?` |
| Multi-character | `->` `**` `//` `<<` `>>` `::` `==` `!=` `!~` `<=` `>=` `??` `..` |
| String delimiter | `"` `"""` |
| Synthetic | `INDENT` `DEDENT` `NEWLINE` |

*(Spec: [LLEX.8.1.1], [LLEX.8.1.3], [LLEX.8.3.1], [LLEX.8.3.2], [LLEX.8.3.3], [LLEX.10.7.1], [LLEX.10.8.5], [LLEX.16.3], [LLEX.17.2], [LLEX.17.6], [LGRA.2.10.1], [LGRA.2.10.2], [LGRA.9.3.1])*

### At sign

`@` is lexed as a token that no production accepts: any use is a parse error.

*(Spec: [LLEX.8.2.1], [LGRA.2.10.3])*

### Lone equals sign

`=` binds a name to the expression after it, in `const_decl`, `let_binding`, `capture_binding`, `unit_inline` and `formula_line`. Anywhere else it is a parse error.

*(Spec: [LLEX.8.2.2], [LGRA.2.10.3])*

### Lone exclamation mark

A `!` that does not start a multi-character token is a lexer error.

*(Spec: [LLEX.8.1.1])*

### Ellipsis

`...` is a lexer error, `ellipsis not valid in DS`.

*(Spec: [LLEX.8.2.3], [LLEX.17.5])*

### Semicolon

`;` is an unexpected character: a lexer error.

*(Spec: [LLEX.16.5], [LGRA.2.10.4])*

### Dot

`.` is slot access, or the separator between a library path and a member. Scope decides which ([Dotted names](program.md#dotted-names)).

*(Spec: [LGRA.2.10.4])*

### Cast and nullable markers

`::` is the postfix conversion cast. `?` marks a nullable type in a type position.

[`??`](../values/null.md#coalesce) is one token by longest match.

*(Spec: [LGRA.2.10.4], [LLEX.10.8.5])*

### Keyword operators

`and`, `or` and `not` are expression operators. `not` is distinct from `no`, which marks pattern absence.

*(Spec: [LGRA.2.11.1], [LGRA.2.11.5])*

## Identifiers

**`NAME ::= <XID identifier, NFC-normalized; XID_Start (∪ '_') narrowed by UAX #39 Identifier_Status, then XID_Continue>`**

`NAME` is the one identifier terminal. Its role is fixed by grammatical position ([Name classification](program.md#name-classification)).

The first character is in (`XID_Start` ∪ `_`) ∩ `Identifier_Status=Allowed`. Each later character is in `XID_Continue` ∩ `Identifier_Status=Allowed`. An identifier starts with no digit and holds no hyphen, ZWJ, ZWNJ, emoji or other non-`XID` symbol. A character glued to a name that these do not admit is a lexer error.

A leading `_` marks a library name internal ([Internal names](imports.md#internal-names)).

*(Spec: [LLEX.10], [LLEX.10.1], [LLEX.10.4], [LLEX.10.5], [LLEX.15.2.1], [LNAM.2.2.1], [LNAM.2.2.2], [LGRA.2.5.1], [LGRA.2.5.2], [LGRA.2.5.4])*

### Identity

Two identifiers are one name exactly when their NFC forms are codepoint-equal. Comparison is case-sensitive: `Reading` and `reading` are two identifiers. Identifiers that render alike and differ in codepoints stay distinct.

Case takes no part in classification, and the compiler requires no case anywhere.

*(Spec: [LNAM.2.1.1], [LNAM.2.3.1], [LNAM.2.3.2], [LNAM.2.5.4])*

### Normalization

The compiler normalizes every identifier to NFC at lex time, before comparison and emission, and validates the normalized form. Compatibility variants are not folded. String-literal content is not normalized.

Legality and normalization use Unicode 16.0 and happen at compile time.

*(Spec: [LNAM.2.2.3], [LNAM.2.2.5], [LNAM.2.4.1], [LNAM.2.4.2], [LLEX.10.8.1], [LLEX.10.8.2])*

### Mixed script

An identifier is refused unless it satisfies UAX #39 Highly Restrictive: one script, or Latin + Han + Hiragana + Katakana, Latin + Han + Bopomofo, or Latin + Han + Hangul, with digits and `_` permitted throughout.

A compiler may also refuse a multi-script identifier that a full UAX #39 set-cover admits.

The check applies to each identifier in every source compiled together, transitively imported libraries included.

*(Spec: [LNAM.2.5.1], [LNAM.2.5.3])*

### Bidirectional text

Strong right-to-left letters are ordinary identifier and string characters.

Bidi control characters are `U+202A`–`202E`, `U+2066`–`2069`, `U+200E`, `U+200F` and `U+061C`:

- an identifier holding one is refused;
- in a string literal or a comment, an embedding, override or isolate left unclosed at its end, or a closer with nothing open, is refused;
- in a string literal or a comment, `U+200E`, `U+200F` and `U+061C` open no scope, and a compiler may permit them.

*(Spec: [LNAM.2.6.1], [LNAM.2.6.2], [LNAM.2.6.3])*

### `TYPE_SYM`

**`TYPE_SYM ::= <the NAME class plus the non-XID unit glyphs (° ′ ″, …)>`**

The terminal at every type position: a `slot: T` annotation, a `let x: T` annotation, a `::T` cast target and a unit literal. It resolves in the [type namespace](program.md#type-namespace).

A run holding a unit glyph that is not a legal `NAME` is read as a `TYPE_SYM`, so `kΩ` and `μs` are unit symbols. A `NAME` never holds a non-`XID` glyph.

*(Spec: [LLEX.10.2], [LLEX.10.8.3], [LNAM.2.2.4], [LGRA.2.5.1], [LGRA.2.5.2])*

### Synthetic names

A name the compiler or the engine makes for itself is `$` followed by the name. `$` is no `NAME` character, so no source text writes one. An author may declare any other `NAME`, `__Foo__` included, subject to [Reserved words](#reserved-words).

*(Spec: [LLEX.10.6.1])*

## Numeric literals

A negative number is unary minus applied to a non-negative literal: `-5` is two tokens.

*(Spec: [LLEX.11.4.1], [LGRA.2.7.6])*

### `INT_LIT`

**`INT_LIT ::= DEC_LIT | HEX_LIT | BIN_LIT | OCT_LIT`**

`DEC_LIT` is digits, `HEX_LIT` starts `0x`, `BIN_LIT` starts `0b` and `OCT_LIT` starts `0o`. A single `_` separates two digits.

A `_` at the end of a digit run, beside a base prefix, a decimal point or an exponent marker, or beside another `_` is a lexer error, unless it is the separator before a unit suffix. A literal past the 64-bit signed range is a lexer error, `integer literal out of range`.

```ds expression
r.n + 1_000
r.n + 0xFF
r.n + 0b1010
r.n + 0o17
```

*(Spec: [LLEX.11.1], [LLEX.11.1.5], [LGRA.2.7.1], [LGRA.2.7.3])*

### `FLOAT_LIT`

**`FLOAT_LIT ::= DEC_LIT '.' DEC_LIT EXPONENT? | DEC_LIT EXPONENT`**

Both sides of the decimal point are required: `.5` and `5.` are lexer errors. The exponent is optional on the dotted form and required on the bare form. Hex floats and typed suffixes (`5L`, `5i32`, `1.0f`) are refused.

The literal reads as the `Float` nearest its value, ties to even. A literal whose value rounds to zero is that zero. A value past the largest finite `Float` is a lexer error with `DS_PARSE_FLOAT_RANGE`: `1.7976931348623157e308` is a literal, and `1.8e308` and `-1e400` are refused.

```ds expression
r.level + 1.5
r.level + 2.5e3
r.level + 1e6
```

*(Spec: [LLEX.11.2], [LLEX.11.2.1], [LLEX.11.2.2], [LLEX.11.2.3], [LLEX.11.2.4], [LGRA.2.7.5])*

### Numeric adjacency

A numeric literal followed by a non-space token resolves as `UNIT_LIT`, then scientific `FLOAT_LIT`, then an error. A digit directly followed by an alphabetic character is a [unit literal](../units/literals.md#adjacency). `30 s` is the integer `30` followed by the identifier `s`.

*(Spec: [LLEX.11.3.1], [LGRA.12.6.1])*

### `time_expr`

**`time_expr ::= UNIT_LIT | NAME`**

The form of a duration: a unit literal of the `time` dimension, or a `const` or [`let`](../rules/let.md#let) binding of time type. Every construct that takes a duration accepts it, except [`after`](../actions/after.md#after), which takes a `UNIT_LIT` only. It takes no sign: `within -5_s` is a parse error. A rate modifier's sign is refused as its [duration refusals](../rules/cooldown.md#duration-refusals) state.

[Duration literals](../units/literals.md#duration-literals) name the units.

*(Spec: [LGRA.2.8.1], [LGRA.2.8.2], [LGRA.2.8.9], [LGRA.2.8.10], [LGRA.6.6.7])*

## String literals

**`STRING_LIT ::= SINGLE_STR | TRIPLE_STR`**

Content is any well-formed UTF-8, including right-to-left text, and is not normalized.

*(Spec: [LLEX.13], [LNAM.2.7.1], [LGRA.2.9.1])*

### `SINGLE_STR`

**`SINGLE_STR ::= '"' SINGLE_CHAR* '"'`**

Holds no raw newline.

*(Spec: [LLEX.13.1.1], [LGRA.2.9.2])*

### `TRIPLE_STR`

**`TRIPLE_STR ::= '"""' TRIPLE_CHAR* '"""'`**

Spans lines. The lexer tracks no indentation inside it. The consumer of the value strips the common leading whitespace of non-empty lines and removes leading and trailing blank lines (`inspect.cleandoc`).

*(Spec: [LLEX.13.1.2], [LLEX.6.7.1], [LGRA.2.9.3])*

### Escape sequences

**`ESCAPE_SEQ ::= '"' | '\'' | '\' | 'n' | 't' | 'r' | 'x' HEX_DIGIT HEX_DIGIT | 'u' HEX_DIGIT{4} | 'U' HEX_DIGIT{8}`**

An unknown escape is refused, as is a `\x`, `\u` or `\U` escape naming U+0000, a surrogate or a value above U+10FFFF.

*(Spec: [LLEX.13], [LLEX.13.1.3], [LGRA.2.9.4], [LGRA.2.9.7])*

### String refusals

A string unterminated at end of file is a lexer error. Single-quoted, raw and byte strings and adjacent-string concatenation are refused.

*(Spec: [LLEX.13.1.4], [LLEX.13.1.5], [LGRA.2.9.5])*

## Lexer error position

A lexer error carries the 1-based line and column of the start of the offending construct.

*(Spec: [LLEX.15.1.1])*

## Reserved words

An author declares no identifier that is a reserved word, at any naming site: a slot, a binding, a schema, a rule, a `const`, a service kwarg or an `opaque type`. A word is reserved as one exact NFC string: `where` is refused, and `Where` is an ordinary identifier. A schema the compiler declares may name a slot with a reserved word, and reading that slot is admissible.

Every `p1` … `p99` is also reserved, with no row of its own.

The refusal's code is the first row that matches:

| Word | Declared as | Code |
|---|---|---|
| `cooldown`, `retain`, `nocooldown`, `as` | anything | `DS_VALIDATE_RESERVED_META_KWARG` |
| reserved by `type` | a schema, a unit or an `opaque type` | `DS_VALIDATE_RESERVED_TYPE_NAME` |
| reserved by [`builtin`](../expr/builtins.md) | a binding, a `let` or a `const` | `DS_VALIDATE_RESERVED_BUILTIN_NAME` |
| reserved by `aggregation` or `alias`, or `p1` … `p99` | a slot | `DS_VALIDATE_COMPANION_SLOT_COLLISION` |
| any other | anything | `DS_VALIDATE_HARD_KEYWORD_NAME` |

```ds declaration error=DS_VALIDATE_HARD_KEYWORD_NAME
const where = 1
```

The `Class` column groups the words the grammar reserves, by role, and changes nothing about a word's reservation or its refusal.

```{include} ../_generated/keywords.md
```

*(Spec: [LLEX.9.2.1], [LLEX.9.5], [LLEX.9.6], [LLEX.9.7], [LLEX.9.8], [LLEX.17.8], [LGRA.2.6])*

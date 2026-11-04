# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Pygments lexer for the DS language.

Source of truth: the specification. The keyword sets are generated from
[LLEX.9.6], the table of every word DS reserves, by `genkeywords.py` beside
this file; the block between the GENERATED markers is its output and
is not edited by hand. Each literal pattern below cites the LLEX clause that
defines it.

Usable two ways:
  * As a Pygments plugin — installed via the ``pygments.lexers`` entry point in
    this directory's ``pyproject.toml`` (``pip install tools/ds_lexer``),
    after which ```ds`` fences highlight anywhere Pygments runs.
  * As a Sphinx/JupyterBook local extension — ``setup(app)`` registers the lexer
    under the alias ``ds`` (see each book's ``_config.yml`` local_extensions).
"""

from pygments.lexer import RegexLexer, bygroups, default, words
from pygments.token import (
    Comment, Keyword, Name, Number, Operator, Punctuation, String, Text,
)

__all__ = ["DSLexer", "setup"]

# --- BEGIN GENERATED: keyword sets from [LLEX.9.6] ---
# Do not edit: regenerate it.
# One tuple per token class. LLEX.9.8 classes the words the grammar
# reserves; every other word goes by its `Reserved by` column.
_DECLARATION = (
    "const",
    "from",
    "import",
    "opaque",
    "rule",
    "schema",
    "series",
    "service",
    "test",
    "unit",
    "use",
)
_ACTION = (
    "cache",
    "cache_delete",
    "call",
    "emit",
    "log",
    "publish",
    "withdraw",
)
_OPERATOR = (
    "and",
    "contains",
    "in",
    "is",
    "not",
    "or",
    "overlaps",
)
_CONSTANT = (
    "NaN",
    "false",
    "inf",
    "nan",
    "null",
    "true",
)
_CLAUSE = (
    "activated",
    "activation",
    "after",
    "alias",
    "all_time",
    "ambient",
    "as",
    "at",
    "base",
    "by",
    "cache_deleted",
    "cached",
    "called",
    "capacity",
    "cooldown",
    "count",
    "default",
    "dimension",
    "emitted",
    "empty",
    "error",
    "explicit",
    "field",
    "filter_fields",
    "for",
    "formula",
    "from_base",
    "fx_pair",
    "gap",
    "has",
    "hold",
    "hydrates",
    "hydration",
    "implicit",
    "initial",
    "inputs",
    "inverting",
    "key",
    "kwarg",
    "latest",
    "let",
    "literal",
    "logged",
    "logical",
    "max_limit",
    "max_window",
    "mutable",
    "never",
    "no",
    "none",
    "on",
    "over",
    "persist",
    "produces",
    "published",
    "record_event",
    "recorded",
    "required",
    "response",
    "responses",
    "retained",
    "retracted",
    "sample",
    "sampled",
    "scalar",
    "scope",
    "skip",
    "sliding",
    "storage",
    "then",
    "timeout",
    "to",
    "to_base",
    "tolerance",
    "ttl",
    "tumbling",
    "type",
    "until",
    "via",
    "where",
    "within",
    "wm",
    "zero",
)
_TYPE = (
    "Bool",
    "Bytes",
    "ComputationError",
    "Date",
    "Duration",
    "Float",
    "Int",
    "Interval",
    "Json",
    "Schema",
    "String",
    "Time",
    "TypeError",
)
_BUILTIN = (
    "abs",
    "active_fraction",
    "bool_and",
    "bool_or",
    "count_distinct",
    "count_of",
    "direction",
    "dwell",
    "first",
    "integral",
    "last",
    "len",
    "max",
    "mean",
    "median",
    "min",
    "monotonic_ns",
    "now",
    "onset_rate",
    "pstdev",
    "pvariance",
    "rate",
    "round",
    "stdev",
    "sum",
    "variance",
)
_KWARG = (
    "filter",
    "limit",
    "nocooldown",
    "retain",
    "value",
)
# --- END GENERATED ---

# THE TOKEN FOR EACH SET, which is this lexer's choice and stated here once:
#   _DECLARATION  Keyword.Declaration  opens a file-level production
#   _ACTION       Keyword.Reserved     heads an action
#   _OPERATOR     Operator.Word        a word of the expression productions
#   _CONSTANT     Keyword.Constant     an `is` constant
#   _CLAUSE       Keyword              every other grammar word
#   _TYPE         Keyword.Type
#   _BUILTIN      Name.Builtin         builtins, aggregations, and `dwell`, an
#                                      aggregation's other name (`alias`)
#   _KWARG        Keyword.Pseudo       a reserved control-plane kwarg name
# The percentile aggregations `p1` … `p99` are reserved as a family with no
# rows in the table ([LLEX.9.5]), so their pattern is written here.
_PERCENTILE = r"\bp[1-9][0-9]?\b"

# --- literals, each from the clause that defines it -------------------------

# [LLEX.11.1]: DEC_LIT ::= DIGIT ('_'? DIGIT)*, one `_` between two digits.
# The based forms take the lowercase prefix the grammar writes.
_DEC = r"[0-9](?:_?[0-9])*"
_HEX = r"0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*"
_BIN = r"0b[01](?:_?[01])*"
_OCT = r"0o[0-7](?:_?[0-7])*"
# [LLEX.11.2]: EXPONENT ::= ('e' | 'E') ('+' | '-')? DIGIT ('_'? DIGIT)*;
# both sides of the point are required ([LLEX.11.2.1]), and the bare form needs
# its exponent ([LLEX.11.2.2]).
_EXP = r"[eE][+-]?[0-9](?:_?[0-9])*"
_FLOAT = rf"{_DEC}\.{_DEC}(?:{_EXP})?|{_DEC}{_EXP}"
# [LLEX.12]: UNIT_LIT ::= DEC_PREFIX '_'? UNIT_SUFFIX. The suffix opens on a
# letter or one of [LLEX.12.2]'s glyphs (° ′ ″ Ω µ Å) and continues with letters,
# digits, the glyphs and `ₙ`; [LLEX.12.2.1]'s look-alikes (μ Ω ʹ ʺ) are folded to
# them by the compiler, so they open a suffix too. [LLEX.11.3.1] / [LUNI.3.1.5]
# withhold a bare `i` / `j` and an `e` / `E` followed by an exponent, which is
# what leaves `1e6` to FLOAT_LIT. A suffix also continues with `_`, which never
# opens one ([LUNI.3.2]): `5_meter_squared` is `5`, the separator and
# `meter_squared`.
_GLYPHS = "°′″ΩµÅμΩʹʺ"
_CONT = "A-Za-z0-9_" + _GLYPHS + "ₙ"
_UNIT = (rf"{_DEC}(?:\.{_DEC})?(?:{_EXP})?_?"
         rf"(?:[eE](?![+\-0-9])[{_CONT}]*"
         rf"|[ij][{_CONT}]+"
         rf"|[A-DF-Za-df-hk-z{_GLYPHS}][{_CONT}]*)")


class DSLexer(RegexLexer):
    """Lexer for the DS rule language (``.ds`` files)."""

    name = "DS"
    aliases = ["ds"]
    filenames = ["*.ds"]
    mimetypes = ["text/x-ds"]
    url = ""

    tokens = {
        "root": [
            (r"[ \t]+", Text),
            (r"\r?\n", Text),
            # [LLEX.4.1]: `#` to the end of the line, outside a string.
            (r"#[^\n]*", Comment.Single),
            # [LLEX.13]: TRIPLE_STR before SINGLE_STR, longest match first.
            (r'"""(?:\\[\s\S]|[^\\])*?"""', String.Doc),
            (r'"(?:\\.|[^"\\\n])*"', String.Double),
            # No RESERVED_IDENT ([LLEX.10.6.1]): `__Foo__` is a NAME
            # like any other, and a synthetic `$` name is never source text.
            # A slot read: the name after `.` is a slot, whatever it spells.
            # Without this, `h.count` or `h.value` would light up as a keyword,
            # and a schema the compiler declares may use those names
            # ([LLEX.9.5]).
            (r"(\.)([^\W\d_]\w*)", bygroups(Punctuation, Name.Attribute)),
            # The keyword sets, before NAME. `words` anchors each at a word
            # boundary, so `count` does not match inside `count_of`.
            (words(_TYPE, prefix=r"\b", suffix=r"\b"), Keyword.Type),
            (words(_CONSTANT, prefix=r"\b", suffix=r"\b"), Keyword.Constant),
            (words(_DECLARATION, prefix=r"\b", suffix=r"\b"), Keyword.Declaration),
            (words(_OPERATOR, prefix=r"\b", suffix=r"\b"), Operator.Word),
            (words(_ACTION, prefix=r"\b", suffix=r"\b"), Keyword.Reserved),
            (words(_CLAUSE, prefix=r"\b", suffix=r"\b"), Keyword),
            (words(_BUILTIN, prefix=r"\b", suffix=r"\b"), Name.Builtin),
            (_PERCENTILE, Name.Builtin),
            (words(_KWARG, prefix=r"\b", suffix=r"\b"), Keyword.Pseudo),
            # Numbers, based forms first so `0x1F` is not a `0` with a unit.
            (_HEX, Number.Hex),
            (_BIN, Number.Bin),
            (_OCT, Number.Oct),
            (_UNIT, Number),
            (_FLOAT, Number.Float),
            (_DEC, Number.Integer),
            # [LLEX.10.1]: NAME is one case-blind terminal over XID, and its role
            # is the grammar's, not the lexer's. [LLEX.10.2]: a run opening on a
            # unit glyph is the TYPE_SYM form (`°C`).
            (rf"[{_GLYPHS}][\w{_GLYPHS}ₙ]*", Name),
            (r"[^\W\d_]\w*", Name),
            # [LREG.6.1]: a regex literal follows `~` or `!~` only.
            (r"!~", Operator, "regex"),
            (r"~", Operator, "regex"),
            # [LLEX.8.1.1] longest match: the multi-character tokens of
            # [LLEX.8.3.2], with `..`, `::`, and `??` ([LLEX.10.8.5]).
            (r"->|\.\.|::|\?\?|==|!=|<=|>=|<<|>>|\*\*|//", Operator),
            # [LLEX.8.3.1]'s single characters, with `-`, `*`, `/`, `<`, `>`,
            # `!` and `?`. No `;`: it is not a token ([LLEX.16.5]), so
            # Pygments renders it as an error, as the compiler refuses it.
            (r"[+\-*/%<>|&^=:!?@]", Operator),
            (r"[()\[\]{},.]", Punctuation),
        ],
        # [LREG.5.1]: `/pattern/flags`, only in regex position.
        "regex": [
            (r"[ \t]+", Text),
            (r"/([^/\n\\]|\\.)+/[A-Za-z]*", String.Regex, "#pop"),
            default("#pop"),
        ],
    }


def setup(app):
    """Register the DS lexer as a Sphinx/JupyterBook local extension."""
    from sphinx.highlighting import lexers
    lexers["ds"] = DSLexer()
    return {
        "version": "0.1",
        "parallel_read_safe": True,
        "parallel_write_safe": True,
    }

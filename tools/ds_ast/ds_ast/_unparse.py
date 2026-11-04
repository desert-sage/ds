# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`unparse`: a tree back to DS source, as `ast.unparse` does for Python.

The output is what `dsc`'s parser reads back into the same tree -- that is the
property the `ds-ast` lane checks over the corpus (tools/ds_ast/DESIGN.md
section 5) -- with every comment and blank line where the tree carries it.

Each construct is written in the one spelling the parser accepts for it, read
off `dsc.parse`, and where the tree does not record which of two spellings
the author used, the one written is stated here:

- a `call`'s `as` goes on the call line, never on a closing `as` line of its
  block; the parser gives both one field;
- a sequence pattern is written one `then` per line, the corpus's form; a
  step's own `where` follows its `within`. There is no sequence-wide `where`:
  the one-line form's trailing one is its last step's ([LGRA.8.5.10]);
- an import list is written unparenthesised, with no trailing comma;
- a docstring or label is `"..."` unless its text holds a newline or a `"`,
  then `\"\"\"...\"\"\"`. The text is the literal's raw content (the tree does not
  decode escapes yet, rung A6), so writing it back between quotes is exact;
- the `use` line goes where its line number puts it among the declarations,
  before one on the same line, and first when it has none.

A literal is written as its `raw` spelling when that spelling still denotes
its `value`, and as a spelling of `value` otherwise (DESIGN.md section 6), so
a transform that changes a value is never contradicted by a stale spelling.

⚠ PARENTHESES ARE INSERTED BY PRECEDENCE, as Python's `unparse` inserts them:
the tree records none (`dsc.expr`). The table is `dsc.parse`'s chain of
levels, lowest first, and the three positions that take a single primary --
a time model's argument, an accuracy value, a kwarg default and the two
hydration limits -- parenthesise anything that is not one.
"""
from __future__ import annotations

import unicodedata
from typing import Any

from . import _nodes as n
from ._base import AST
from ._tools import iter_child_nodes, walk

_INDENT = "    "

# `dsc.parse`'s expression levels, lowest binding first.
_OR, _AND, _NOT, _CMP, _COALESCE, _MATCH, _REL, _RANGE = range(1, 9)
_BITOR, _BITXOR, _BITAND, _SHIFT, _ADD, _MUL, _POW, _UNARY = range(9, 17)
_POSTFIX, _ATOM = 17, 18

_BINOPS: dict[type, tuple[str, int]] = {
    n.Coalesce: ("??", _COALESCE),
    n.In: ("in", _REL), n.Contains: ("contains", _REL),
    n.Overlaps: ("overlaps", _REL),
    n.Range: ("..", _RANGE),
    n.BitOr: ("|", _BITOR), n.BitXor: ("^", _BITXOR),
    n.BitAnd: ("&", _BITAND),
    n.LShift: ("<<", _SHIFT), n.RShift: (">>", _SHIFT),
    n.Add: ("+", _ADD), n.Sub: ("-", _ADD),
    n.Mult: ("*", _MUL), n.Div: ("/", _MUL), n.FloorDiv: ("//", _MUL),
    n.Mod: ("%", _MUL),
    n.Pow: ("**", _POW),
}
# `in` / `..` are not loops in the grammar: `a in b in c` does not parse, so
# both operands of these sit one level up rather than the left one staying.
_NON_ASSOCIATIVE = {_REL, _RANGE}
_CMPOPS = {n.Eq: "==", n.NotEq: "!=", n.Lt: "<", n.LtE: "<=", n.Gt: ">",
           n.GtE: ">="}
_UNARY_OPS = {n.USub: "-", n.UAdd: "+", n.Invert: "~"}
_LOG_LEVELS = {n.LogDebug: "debug", n.LogInfo: "info",
               n.LogWarning: "warning", n.LogError: "error",
               n.LogCritical: "critical"}
_MARKERS = {n.Key: "key", n.Mutable: "mutable", n.Sampled: "sampled",
            n.Retained: "retained"}
_GAPS = {n.GapHold: "hold", n.GapZero: "zero", n.GapSkip: "skip"}


def unparse(node: AST, *, line_map: bool = False) -> Any:
    """DS source for `node`: a whole `Module`, one declaration or statement,
    or an expression.

    With `line_map=True` it returns `(source, lines)` instead, where
    `lines[i]` is the tuple of nodes line `i + 1` of `source` was written
    for, outermost first: the declarations and statements being written,
    then each node with text on the line, in the order it was written. A
    comment or blank line belongs to the node it precedes; an expression's
    source is one line. A tree built as nodes has no source of its own, so
    `dsc`'s diagnostics name lines of this text, and the map carries each
    back to the nodes, whose `lineno` a generator sets from its own source.
    `compile` does that."""
    writer = _Unparser(track=line_map)
    if isinstance(node, (n.expr, n.pattern, n.type_ref, n.scope)):
        text = writer.expression_like(node)
        return (text, [_unique(writer.pending)]) if line_map else text
    writer.node(node, 0)
    text = "".join(writer.out)
    return (text, writer.lines) if line_map else text


def _unique(nodes: list[AST]) -> tuple[AST, ...]:
    """`nodes` without repeats, in order: a line's owner is also marked by
    the helper that writes it."""
    seen: set[int] = set()
    out = []
    for node in nodes:
        if id(node) not in seen:
            seen.add(id(node))
            out.append(node)
    return tuple(out)


class _Unparser:
    def __init__(self, track: bool = False) -> None:
        self.out: list[str] = []
        # The line map (`unparse(line_map=True)`): one entry per line
        # written; the `w_` nodes being written; the nodes whose text has
        # been made since the last line, which the next line holds.
        self.track = track
        self.lines: list[tuple[AST, ...]] = []
        self.stack: list[AST] = []
        self.pending: list[AST] = []

    # -- lines and trivia ---------------------------------------------------

    def mark(self, node: AST) -> None:
        """`node`'s text is being made, for the next line written."""
        if self.track:
            self.pending.append(node)
            self.mark_leaves(node)

    def mark_leaves(self, node: AST) -> None:
        """`node`'s unlocated children with none of their own -- an
        operator, a log level, a gap policy -- are written with it, and no
        helper is called for them. A located one (`no response`) can have a
        line of its own, so it is left to the code that writes it."""
        for child in iter_child_nodes(node):
            if "lineno" not in child._attributes and \
                    next(iter_child_nodes(child), None) is None:
                self.pending.append(child)

    def emit(self, text: str, owner: AST | None, *, written: bool,
             also: AST | None = None) -> None:
        """`text`, whole lines, mapped to the nodes being written, `owner`
        and `also`, and when `written` to every node whose text it holds. A
        `written` text can be several lines: a triple-quoted string."""
        self.out.append(text)
        if not self.track:
            return
        here = list(self.stack)
        here += [x for x in (owner, also) if x is not None]
        if written:
            here += self.pending
            self.pending = []
        self.lines += [_unique(here)] * text.count("\n")

    def line(self, level: int, text: str, owner: AST | None = None) -> None:
        """One source line, with `owner`'s blank lines and comments before it
        and its trailing comment after it."""
        after = None
        if owner is not None:
            for c in getattr(owner, "comments_before", None) or []:
                self.emit("\n" * getattr(c, "blank_lines_before", 0), owner,
                          written=False)
                self.emit(_INDENT * level + c.text + "\n", owner,
                          written=False, also=c)
            self.emit("\n" * (getattr(owner, "blank_lines_before", 0) or 0),
                      owner, written=False)
            after = getattr(owner, "comment_after", None)
            if after is not None:
                text = f"{text}  {after.text}"
        self.emit(_INDENT * level + text + "\n", owner, written=True,
                  also=after)

    def node(self, node: AST, level: int) -> None:
        method = getattr(self, "w_" + type(node).__name__, None)
        if method is None:
            raise ValueError(f"cannot unparse a {type(node).__name__} "
                             f"on its own")
        self.stack.append(node)
        if self.track:
            # Its leaves are on its first line written.
            self.mark_leaves(node)
        method(node, level)
        self.stack.pop()

    def block(self, nodes: list[AST], level: int) -> None:
        for item in nodes:
            self.node(item, level)

    def doc(self, text: str | None, level: int) -> None:
        if text is not None:
            self.line(level, _string(text))

    # -- the module ----------------------------------------------------------

    def w_Module(self, node: n.Module, level: int) -> None:
        body = list(node.body)
        use = node.use
        at = 0
        # Before the first declaration on its line or after: a parsed `use`
        # shares a line with none, and a generator that gives every node one
        # line keeps it first. A `use` the author put after a rule
        # stays there, for `dsc` to refuse ([LGRA.3.2], USE_NOT_FIRST).
        if use is not None and getattr(use, "lineno", None) is not None:
            at = next((i for i, d in enumerate(body)
                       if getattr(d, "lineno", 0) >= use.lineno), len(body))
        for i, decl in enumerate(body):
            if use is not None and i == at:
                self.node(use, level)
            self.node(decl, level)
        if use is not None and at >= len(body):
            self.node(use, level)
        for c in node.comments_end:
            self.emit("\n" * c.blank_lines_before, None, written=False)
            self.emit(c.text + "\n", None, written=False, also=c)

    def w_Use(self, node: n.Use, level: int) -> None:
        if not node.settings:
            self.line(level, f"use {node.dialect}", node)
            return
        self.line(level, f"use {node.dialect}:", node)
        for s in node.settings:
            self.mark(s)
            value = "true" if s.value else "false"
            self.line(level + 1, f"{s.capability}: {value}")

    # -- declarations --------------------------------------------------------

    def w_Import(self, node: n.Import, level: int) -> None:
        alias = f" as {node.asname}" if node.asname else ""
        self.line(level, f"import {'.'.join(node.path)}{alias}", node)

    def w_ImportFrom(self, node: n.ImportFrom, level: int) -> None:
        for a in node.names:
            self.mark(a)
        names = ", ".join(a.name + (f" as {a.asname}" if a.asname else "")
                          for a in node.names)
        self.line(level, f"from {'.'.join(node.path)} import {names}", node)

    def w_Schema(self, node: n.Schema, level: int) -> None:
        scope = f" {self.scope(node.scope)}" if node.scope is not None else ""
        self.line(level, f"schema {node.name}{scope}:", node)
        self.doc(node.docstring, level + 1)
        self.block(node.slots, level + 1)

    def scope(self, node: n.scope) -> str:
        self.mark(node)
        if isinstance(node, n.Unprefixed):
            return self.scope(node.scope).removeprefix("scope ")
        if isinstance(node, n.Explicit):
            return "scope explicit"
        if isinstance(node, n.Activation):
            return "scope activation"
        if isinstance(node, n.BareAmbient):
            return "scope ambient"
        ambient = " ambient" if node.ambient else ""
        if isinstance(node, n.Logical):
            return f"scope logical{ambient}"
        if isinstance(node, n.Ttl):
            return f"scope ttl {self.expr(node.duration)}{ambient}"
        raise ValueError(f"not a scope: {type(node).__name__}")

    def w_Slot(self, node: n.Slot, level: int) -> None:
        parts = [f"{node.name}: {node.type}{'?' if node.nullable else ''}"]
        if node.capacity is not None:
            parts.append(f"capacity {self.expr(node.capacity)}")
        for m in node.markers:
            self.mark(m)
            parts.append(_MARKERS[type(m)])
        if node.tolerance is not None:
            parts.append(f"tolerance {self.expr(node.tolerance)}")
        if node.docstring is not None:
            parts.append(_string(node.docstring))
        self.line(level, " ".join(parts), node)

    def rate(self, r: n.rate) -> str:
        self.mark(r)
        if isinstance(r, n.RateKey):
            # `by: none` is the empty list ([LCDB.3.3.4]).
            paths = ", ".join(self.expr(p) for p in r.paths) or "none"
            return f" by: {paths}"
        return f" cooldown {self.expr(r.duration)}"

    def w_Rule(self, node: n.Rule, level: int) -> None:
        rates = "".join(self.rate(r) for r in node.rate)
        self.line(level, f"rule {node.name}{rates}:", node)
        self.doc(node.docstring, level + 1)
        self.block(node.lhs, level + 1)
        self.line(level, "->")
        self.block(node.lets, level + 1)
        self.block(node.actions, level + 1)
        self.block(node.afters, level + 1)

    def w_Const(self, node: n.Const, level: int) -> None:
        if node.colon_form:
            text = f"const {node.name}: {self.expr(node.value)}"
        else:
            ann = (f": {self.annotation(node.annotation)}"
                   if node.annotation is not None else "")
            text = f"const {node.name}{ann} = {self.expr(node.value)}"
        self.line(level, text, node)

    def annotation(self, node: n.Annotation) -> str:
        self.mark(node)
        return f"{node.type}{'?' if node.nullable else ''}"

    def w_Series(self, node: n.Series, level: int) -> None:
        ref = f"{node.schema}.{node.slot}" if node.schema else node.slot
        opts = ""
        if node.options:
            opts = " (" + ", ".join(self.series_option(o)
                                    for o in node.options) + ")"
        self.line(level, f"series {ref}{opts}:", node)
        self.doc(node.docstring, level + 1)
        self.block(node.lines, level + 1)

    def series_option(self, node: n.series_option) -> str:
        self.mark(node)
        if isinstance(node, n.Persist):
            return f"persist: {self.expr(node.duration)}"
        if isinstance(node, n.Capacity):
            return f"capacity: {self.expr(node.samples)}"
        if isinstance(node, n.Nulls):
            return f"nulls: {node.policy}"
        return f"by: {node.slot if node.slot is not None else 'none'}"

    def w_SeriesLine(self, node: n.SeriesLine, level: int) -> None:
        parts = [", ".join(node.aggregations), self.time_model(node.time)]
        if node.accuracy is not None:
            parts.append(self.accuracy(node.accuracy))
        if node.gap is not None:
            parts.append(f"gap {_GAPS[type(node.gap)]}")
        if node.asname is not None:
            parts.append(f"as {node.asname}")
        self.line(level, " ".join(parts), node)

    def time_model(self, node: n.time_model) -> str:
        self.mark(node)
        if isinstance(node, n.AllTime):
            return "all_time"
        if isinstance(node, n.Sliding):
            return f"sliding {self.expr(node.window, _ATOM)}"
        if isinstance(node, n.Tumbling):
            return f"tumbling {self.expr(node.window, _ATOM)}"
        return f"sample {self.expr(node.size, _ATOM)}"

    def accuracy(self, node: n.accuracy) -> str:
        self.mark(node)
        if isinstance(node, n.Exact):
            return "exact"
        if isinstance(node, n.BoundDeterministic):
            return "bound deterministic"
        word = type(node).__name__.lower()
        return f"{word} {self.expr(node.value, _ATOM)}"

    def w_Service(self, node: n.Service, level: int) -> None:
        self.line(level, f"service {'.'.join(node.name)}:", node)
        self.doc(node.docstring, level + 1)
        self.block(node.kwargs, level + 1)
        if node.hydration:
            self.line(level + 1, "hydration:")
            self.block(node.hydration, level + 2)
        # The response is the body's last line ([LGRA.23.1]).
        if node.response is not None:
            self.mark(node.response)
        if isinstance(node.response, n.ResponseSchema):
            self.line(level + 1, f"response {node.response.name}")
        elif isinstance(node.response, n.NoServiceResponse):
            self.line(level + 1, "no response")

    def w_ServiceKwarg(self, node: n.ServiceKwarg, level: int) -> None:
        mods = []
        for m in node.modifiers:
            self.mark(m)
            if isinstance(m, n.Default):
                # A literal, "optionally signed" (LGRA.23.1): `default -5`, and
                # never `default (-5)`, which the grammar does not admit. So
                # the value is written at unary precedence, where a sign needs
                # no parentheses, rather than as an atom.
                mods.append(f"default {self.expr(m.value, _UNARY)}")
            else:
                mods.append(type(m).__name__.lower())
        text = " ".join([f"kwarg {node.name}: {node.type}", *mods])
        self.line(level, text, node)

    def w_Hydrates(self, node: n.Hydrates, level: int) -> None:
        self.line(level, f"hydrates: {', '.join(node.schemas)}", node)

    def w_MaxWindow(self, node: n.MaxWindow, level: int) -> None:
        self.line(level, f"max_window: {self.expr(node.value, _ATOM)}", node)

    def w_MaxLimit(self, node: n.MaxLimit, level: int) -> None:
        self.line(level, f"max_limit: {self.expr(node.value, _ATOM)}", node)

    def w_FilterFields(self, node: n.FilterFields, level: int) -> None:
        self.line(level, "filter_fields:", node)
        for f in node.fields:
            self.mark(f)
            ops = ", ".join(_CMPOPS[type(o)] for o in f.ops)
            self.line(level + 1, f"{f.name}: {ops}")

    def w_UnitDimension(self, node: n.UnitDimension, level: int) -> None:
        self.line(level, f"unit dimension {node.name} storage {node.storage} "
                  f"base {node.base}", node)

    def w_UnitScalar(self, node: n.UnitScalar, level: int) -> None:
        label = f" label {_string(node.label)}" if node.label is not None else ""
        self.line(level, f"unit scalar {node.name} storage {node.storage}"
                  f"{label}", node)

    def w_UnitSymbol(self, node: n.UnitSymbol, level: int) -> None:
        label = f" label {_string(node.label)}" if node.label is not None else ""
        head = f"unit {node.symbol}: {node.dimension}"
        body = node.body
        self.mark(body)
        if isinstance(body, n.Tier2):
            if node.aliases:
                raise ValueError("a tier-2 unit takes no aliases "
                                 "(`dsc.parse` luni_4_3_parse_tier2)")
            self.line(level, f"{head}:{label}", node)
            self.line(level + 1, f"to_base: {self.expr(body.to_base)}")
            self.line(level + 1, f"from_base: {self.expr(body.from_base)}")
            return
        affine = (f" = {self.expr(body.expr)}"
                  if isinstance(body, n.Affine) else "")
        aliases = (" alias " + ", ".join(node.aliases)) if node.aliases else ""
        self.line(level, f"{head}{affine}{label}{aliases}", node)

    def w_UnitFormula(self, node: n.UnitFormula, level: int) -> None:
        mods = "".join(" " + type(m).__name__.lower() for m in node.modifiers)
        self.line(level, f"unit formula {node.name}{mods}:", node)
        self.block(node.lines, level + 1)

    def w_FormulaLine(self, node: n.FormulaLine, level: int) -> None:
        self.line(level, f"{node.name}({node.param}: {node.param_type}): "
                  f"{node.returns} = {self.expr(node.body)}", node)

    def w_UnitFxPair(self, node: n.UnitFxPair, level: int) -> None:
        self.line(level, f"unit fx_pair {node.name}: {node.from_unit} to "
                  f"{node.to_unit}", node)
        self.line(level + 1, f"via {node.via} where {self.expr(node.where)}")
        self.line(level + 1, f"field {node.numerator} / {node.denominator}")

    def w_Opaque(self, node: n.Opaque, level: int) -> None:
        self.line(level, f"opaque type {node.name} over "
                  f"{node.representation}", node)

    # The ruleset's `initial:` block ([LGRA.24.1]): a test's `initial`
    # section's items, written the same way, at the top level.
    def w_InitialBlock(self, node: n.InitialBlock, level: int) -> None:
        self.line(level, "initial:", node)
        self.block(node.items, level + 1)

    # -- tests, [LTSL] ---------------------------------------------------------

    def w_Test(self, node: n.Test, level: int) -> None:
        self.line(level, f"test {self.expr(node.name)}:", node)
        self.block(node.sections, level + 1)

    def w_Initial(self, node: n.Initial, level: int) -> None:
        self.line(level, "initial:", node)
        self.block(node.items, level + 1)

    def w_Inputs(self, node: n.Inputs, level: int) -> None:
        self.line(level, "inputs:", node)
        self.block(node.blocks, level + 1)

    def w_Responses(self, node: n.Responses, level: int) -> None:
        self.line(level, "responses:", node)
        self.block(node.stubs, level + 1)

    def w_Produces(self, node: n.Produces, level: int) -> None:
        self.line(level, "produces:", node)
        self.block(node.assertions, level + 1)

    def w_Until(self, node: n.Until, level: int) -> None:
        self.line(level, f"until {self.expr(node.when, _ATOM)}", node)

    def fact(self, node: n.Fact) -> str:
        self.mark(node)
        return f"{self.type_ref(node.schema)}{self.args(node.args)}"

    def w_Fact(self, node: n.Fact, level: int) -> None:
        self.line(level, self.fact(node), node)

    def w_InitialFact(self, node: n.InitialFact, level: int) -> None:
        self.line(level, self.fact(node.fact), node)

    def w_CacheSeed(self, node: n.CacheSeed, level: int) -> None:
        self.line(level, f"cache {self.expr(node.key)}: "
                  f"{self.expr(node.value)}", node)

    def w_CacheBlock(self, node: n.CacheBlock, level: int) -> None:
        self.line(level, "cache:", node)
        self.block(node.seeds, level + 1)

    def w_Seed(self, node: n.Seed, level: int) -> None:
        self.line(level, f"{self.expr(node.key)}: {self.expr(node.value)}",
                  node)

    def w_At(self, node: n.At, level: int) -> None:
        self.line(level, f"at {self.expr(node.when, _ATOM)}:", node)
        self.block(node.facts, level + 1)

    def w_ForCall(self, node: n.ForCall, level: int) -> None:
        text = f"for call {self.service(node.library, node.service)}"
        text += self.args(node.args)
        if node.correlation is not None:
            text += f" as {self.expr(node.correlation)}"
        if node.after is not None:
            text += f" after {self.expr(node.after, _ATOM)}"
        self.line(level, text + ":", node)
        self.block(node.replies, level + 1)

    def w_Reply(self, node: n.Reply, level: int) -> None:
        self.line(level, self.fact(node.fact), node)

    def w_NoResponse(self, node: n.NoResponse, level: int) -> None:
        self.line(level, "no response", node)

    def w_Assertion(self, node: n.Assertion, level: int) -> None:
        never = "never " if node.never else ""
        self.line(level, never + self.head(node.head), node)

    def service(self, library: list[str], service: list[str]) -> str:
        """A service by its own dotted name. ⚠ `library` is always empty: a
        service is not reached through a library ([LGRA.10.1.6]) and `;` is no
        DS token, so a non-empty one has no spelling."""
        if library:
            raise ValueError(f"a service named through library "
                             f"{'.'.join(library)!r} has no DS spelling")
        return ".".join(service)

    def head(self, node: n.test_head) -> str:
        self.mark(node)
        if isinstance(node, n.Activated):
            return f"activated {node.rule}"
        if isinstance(node, (n.Emitted, n.Published)):
            word = "emitted" if isinstance(node, n.Emitted) else "published"
            text = f"{word} {self.type_ref(node.schema)}{self.args(node.args)}"
            if node.where is not None:
                text += f" {node.binding} where {self.expr(node.where)}"
            return text
        if isinstance(node, n.Retracted):
            return f"retracted {self.type_ref(node.schema)}{self.args(node.args)}"
        if isinstance(node, n.Recorded):
            return f"recorded {node.kind}"
        if isinstance(node, n.Called):
            text = f"called {self.service(node.library, node.service)}"
            if node.correlation is not None:
                text += f" as {self.expr(node.correlation)}"
            return text
        if isinstance(node, n.Cached):
            text = f"cached {self.expr(node.key)}"
            if node.value is not None:
                text += f": {self.expr(node.value)}"
            return text
        if isinstance(node, n.CacheDeleted):
            return f"cache_deleted {self.expr(node.key)}"
        if isinstance(node, n.Logged):
            if isinstance(node.level, n.LogUnknown):
                word = node.level.written
            else:
                word = _LOG_LEVELS[type(node.level)]
            sub = (f" {self.expr(node.substring)}"
                   if node.substring is not None else "")
            return f"logged {word}{sub}"
        if isinstance(node, n.WmHas):
            return f"wm has {self.type_ref(node.schema)}{self.args(node.args)}"
        if isinstance(node, n.WmCount):
            return (f"wm count {self.type_ref(node.schema)} == "
                    f"{self.expr(node.count, _ATOM)}")
        if isinstance(node, n.WmEmpty):
            return "wm empty"
        raise ValueError(f"not a test head: {type(node).__name__}")

    # -- the rule's left-hand side ------------------------------------------

    def w_PatternClause(self, node: n.PatternClause, level: int) -> None:
        pattern = node.pattern
        if isinstance(pattern, n.Sequence) and pattern.steps:
            self.mark(pattern)
            head = ("latest " if pattern.latest else "") + \
                self.body(pattern.head)
            self.line(level, head, node)
            for step in pattern.steps:
                self.line(level, self.then(step, own_line=True))
            return
        self.line(level, self.pattern(pattern), node)

    def w_ThenClause(self, node: n.ThenClause, level: int) -> None:
        self.line(level, self.then(node.step, own_line=True), node)

    def pattern(self, node: n.pattern) -> str:
        self.mark(node)
        if isinstance(node, n.Simple):
            return self.body(node.body)
        if isinstance(node, n.Negated):
            body = self.body(node.body)
            return f"no ({body})" if node.parenthesised else f"no {body}"
        # The one-line form. A trailing `where` is the LAST step's
        # ([LGRA.8.5.10]), so only that step may carry one here.
        text = ("latest " if node.latest else "") + self.body(node.head)
        for i, step in enumerate(node.steps):
            last = i == len(node.steps) - 1
            text += " " + self.then(step, own_line=last)
        return text

    def then(self, step: n.Then, *, own_line: bool) -> str:
        """`own_line`: whether a `where` after the `within` can be written --
        on a step's own line, or as a one-line sequence's last step."""
        self.mark(step)
        where = step.body.where
        body = self.body(step.body, with_where=False)
        text = f"then {'latest ' if step.latest else ''}{body} within " \
               f"{self.expr(step.within)}"
        if where is not None:
            if not own_line:
                raise ValueError("a step's own `where` needs the step on its "
                                 "own line, or last on a one-line sequence")
            text += " " + self.where(step.body)
        return text

    def body(self, node: n.PatternBody, *, with_where: bool = True) -> str:
        self.mark(node)
        parts = [self.type_ref(node.type)]
        if node.binding is not None:
            parts.append(node.binding)
        if node.within is not None:
            parts.append(f"within {self.expr(node.within)}")
        if with_where and node.where is not None:
            parts.append(self.where(node))
        return " ".join(parts)

    def where(self, node: n.PatternBody) -> str:
        """`where <cond>`, or [LREG.4.1]'s `where (a, b) = <cond>`: the
        condition is the whole clause, so the capture list is only a prefix."""
        if node.captures:
            return f"where ({', '.join(node.captures)}) = {self.expr(node.where)}"
        return f"where {self.expr(node.where)}"

    def type_ref(self, node: n.type_ref) -> str:
        self.mark(node)
        if isinstance(node, n.QualifiedType):
            # [LGRA.8.1]: `type_ref ::= NAME ('.' NAME)*`.
            return f"{'.'.join(node.library)}.{node.name}"
        return node.name

    # -- the rule's right-hand side -----------------------------------------

    def w_Let(self, node: n.Let, level: int) -> None:
        if not node.bindings:
            raise ValueError("a `let` with no bindings")
        first, *rest = node.bindings
        self.line(level, f"let {self.binding(first)}", node)
        for b in rest:
            self.line(level + 1, self.binding(b), b)

    def binding(self, node: n.let_binding) -> str:
        self.mark(node)
        if isinstance(node, n.LetCapture):
            return f"({', '.join(node.names)}) = {self.expr(node.value)}"
        ann = (f": {self.annotation(node.annotation)}"
               if node.annotation is not None else "")
        return f"{node.name}{ann} = {self.expr(node.value)}"

    def args(self, keywords: list[n.keyword]) -> str:
        return "".join(" " + self.keyword(k) for k in keywords)

    def keyword(self, node: n.keyword) -> str:
        self.mark(node)
        if node.value is None:
            return node.arg
        return f"{node.arg}: {self.expr(node.value)}"

    def kwarg_block(self, keywords: list[n.keyword], level: int) -> None:
        for k in keywords:
            self.line(level, self.keyword(k), k)

    def w_Log(self, node: n.Log, level: int) -> None:
        if isinstance(node.level, n.LogUnknown):
            word = node.level.written
        else:
            word = _LOG_LEVELS[type(node.level)]
        self.line(level, f"log {word} {self.expr(node.message)}"
                  f"{self.args(node.args)}", node)

    def w_ServiceCall(self, node: n.ServiceCall, level: int) -> None:
        service = self.service(node.library, node.service)
        corr =(f" as {self.expr(node.correlation)}"
                if node.correlation is not None else "")
        self.line(level, f"call {service}{self.args(node.args)}{corr}", node)
        self.kwarg_block(node.block, level + 1)
        self.block(node.continuations, level + 1)

    def _verb(self, word: str, node: Any, level: int, *, block: bool) -> None:
        self.line(level, f"{word}{self.args(node.args)}", node)
        if node.block:
            if not block:
                raise ValueError(f"`{word.split()[0]}` takes no indented "
                                 f"block (`dsc.parse` lcco_2_1_action_block)")
            self.kwarg_block(node.block, level + 1)

    def w_Emit(self, node: n.Emit, level: int) -> None:
        self._verb(f"emit {self.type_ref(node.schema)}", node, level,
                   block=True)

    def w_Publish(self, node: n.Publish, level: int) -> None:
        self._verb(f"publish {self.type_ref(node.schema)}", node, level,
                   block=True)

    def w_RecordEvent(self, node: n.RecordEvent, level: int) -> None:
        self._verb(f"record_event {self.type_ref(node.schema)}", node, level,
                   block=True)

    def w_Cache(self, node: n.Cache, level: int) -> None:
        self._verb("cache", node, level, block=False)

    def w_CacheDelete(self, node: n.CacheDelete, level: int) -> None:
        self._verb("cache_delete", node, level, block=False)

    def w_Withdraw(self, node: n.Withdraw, level: int) -> None:
        self.line(level, f"withdraw {node.binding}{self.args(node.args)}",
                  node)

    def w_OnResponse(self, node: n.OnResponse, level: int) -> None:
        self.line(level, f"on {self.expr(node.test)}:", node)
        self.block(node.body, level + 1)

    def w_OnTimeout(self, node: n.OnTimeout, level: int) -> None:
        self.line(level, f"timeout {self.expr(node.duration)}:", node)
        self.block(node.body, level + 1)

    def w_OnError(self, node: n.OnError, level: int) -> None:
        code = f" {'.'.join(node.code)}" if node.code else ""
        self.line(level, f"error{code}:", node)
        self.block(node.body, level + 1)

    def w_After(self, node: n.After, level: int) -> None:
        corr = (f" as {self.expr(node.correlation)}"
                if node.correlation is not None else "")
        self.line(level, f"after {self.expr(node.duration)}{corr}:", node)
        self.block(node.body, level + 1)
        self.block(node.nested, level + 1)

    # -- expressions ---------------------------------------------------------

    def expression_like(self, node: AST) -> str:
        if isinstance(node, n.expr):
            return self.expr(node)
        if isinstance(node, n.pattern):
            return self.pattern(node)
        if isinstance(node, n.type_ref):
            return self.type_ref(node)
        return self.scope(node)

    def expr(self, node: n.expr, context: int = 0) -> str:
        """`node` written to sit where the grammar expects level `context`,
        parenthesised if it binds more loosely."""
        text, level = self.expr_level(node)
        if level < context:
            return f"({text})"
        return text

    def expr_level(self, node: n.expr) -> tuple[str, int]:
        self.mark(node)
        if isinstance(node, n.BoolOp):
            level = _OR if isinstance(node.op, n.Or) else _AND
            word = " or " if level == _OR else " and "
            # Left-nested in the parser: every operand but the first sits one
            # level up, and a nested BoolOp of the same kind as the first
            # operand re-flattens, which is the same tree.
            parts = [self.expr(node.values[0], level)]
            parts += [self.expr(v, level + 1) for v in node.values[1:]]
            return word.join(parts), level
        if isinstance(node, n.UnaryOp):
            if isinstance(node.op, n.Not):
                return f"not {self.expr(node.operand, _NOT)}", _NOT
            op = _UNARY_OPS[type(node.op)]
            operand = self.expr(node.operand, _UNARY)
            # `- -x` and `--x`: the lexer has no `--`, but a space keeps a
            # reader from seeing one.
            sep = " " if operand.startswith(("-", "+", "~")) else ""
            return f"{op}{sep}{operand}", _UNARY
        if isinstance(node, n.BinOp):
            symbol, level = _BINOPS[type(node.op)]
            if level == _POW:
                left = self.expr(node.left, _UNARY)
                right = self.expr(node.right, _POW)
            elif level in _NON_ASSOCIATIVE:
                left = self.expr(node.left, level + 1)
                right = self.expr(node.right, level + 1)
            else:
                left = self.expr(node.left, level)
                right = self.expr(node.right, level + 1)
            return f"{left} {symbol} {right}", level
        if isinstance(node, n.Compare):
            parts = [self.expr(node.left, _COALESCE)]
            for op, right in zip(node.ops, node.comparators):
                parts += [_CMPOPS[type(op)], self.expr(right, _COALESCE)]
            return " ".join(parts), _CMP
        if isinstance(node, n.Is):
            neg = " not" if node.negated else ""
            return (f"{self.expr(node.operand, _COALESCE)} is{neg} "
                    f"{self.is_subject(node.subject)}"), _CMP
        if isinstance(node, n.Match):
            op = "!~" if node.negated else "~"
            return (f"{self.expr(node.operand, _REL)} {op} "
                    f"/{node.pattern}/{node.flags}"), _MATCH
        if isinstance(node, n.Attribute):
            return f"{self.postfix_operand(node.value)}.{node.attr}", _POSTFIX
        if isinstance(node, n.Subscript):
            return (f"{self.postfix_operand(node.value)}"
                    f"[{self.expr(node.index)}]"), _POSTFIX
        if isinstance(node, n.Call):
            args = ", ".join(self.expr(a) for a in node.args)
            return f"{self.postfix_operand(node.func)}({args})", _POSTFIX
        if isinstance(node, n.Cast):
            null = "?" if node.nullable else ""
            return (f"{self.postfix_operand(node.operand)}::{node.type}{null}",
                    _POSTFIX)
        if isinstance(node, n.Name):
            return node.id, _ATOM
        if isinstance(node, n.QualifiedName):
            # `lib.NAME` ([LGRA.22.6]). `dsc` emits an `Attribute` chain for
            # a library member, resolved by scope ([LGRA.22.9]); this node
            # unparses for a tree built by hand.
            return f"{'.'.join(node.library)}.{node.id}", _POSTFIX
        if isinstance(node, n.Constant):
            return _constant(node)
        if isinstance(node, n.Quantity):
            return _quantity(node), _ATOM
        if isinstance(node, n.JoinedStr):
            return self.joined(node), _ATOM
        raise ValueError(f"not an expression: {type(node).__name__}")

    def postfix_operand(self, node: n.expr) -> str:
        """A postfix's operand. ⚠ A BARE LITERAL TAKES NO SUFFIX (`dsc.parse`
        `bare_literal_token`), so one is parenthesised even though it
        binds tightly enough."""
        text, level = self.expr_level(node)
        if level < _POSTFIX or isinstance(node, (n.Constant, n.Quantity,
                                                 n.JoinedStr)):
            return f"({text})"
        return text

    def is_subject(self, node: n.is_subject) -> str:
        self.mark(node)
        if isinstance(node, n.IsNull):
            return "null"
        if isinstance(node, n.IsBool):
            return "true" if node.value else "false"
        if isinstance(node, n.IsInf):
            return "-inf" if node.negative else "inf"
        if isinstance(node, n.IsNaN):
            return "NaN"
        return node.tag

    def joined(self, node: n.JoinedStr) -> str:
        if node.raw is not None and _unchanged(node):
            # The author's spelling holds every site, so each is on its line.
            for sub in walk(node):
                self.mark(sub)
            return node.raw
        parts = []
        for v in node.values:
            self.mark(v)
            if isinstance(v, n.FormattedValue):
                spec = f":{v.format_spec}" if v.format_spec else ""
                parts.append("{" + self.expr(v.value) + spec + "}")
            else:
                parts.append(_encode(str(v.value)))
        return '"' + "".join(parts) + '"'


def string_state(node: AST) -> Any:
    """What a string node says, in a form that compares equal exactly when
    it says the same thing -- None for a node that is not a string. `parse`
    records it on every string it builds, and `unparse` writes the author's
    `raw` only while the node still says it, so no second reader of
    [LGRA.2.9.1]'s escapes lives in Python."""
    if isinstance(node, n.Constant) and isinstance(node.value, str):
        return ("str", node.value)
    if isinstance(node, n.JoinedStr):
        parts = []
        for v in node.values:
            if isinstance(v, n.FormattedValue):
                parts.append(("site", unparse(v.value), v.format_spec))
            else:
                parts.append(("text", getattr(v, "value", None)))
        return ("joined", tuple(parts))
    return None


def _unchanged(node: AST) -> bool:
    read_as = getattr(node, "_read_as", None)
    return read_as is not None and read_as == string_state(node)


def _encode(text: str) -> str:
    """`text` as the inside of a DS string literal: escaped per
    [LGRA.2.9.1], and every brace doubled, since `{{` / `}}` escape a
    brace in every string position ([LGRA.2.9.6.8])."""
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\0":
            out.append("\\0")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append(f"\\x{ord(ch):02X}")
        elif ch in "{}":
            out.append(ch * 2)
        else:
            out.append(ch)
    return "".join(out)


def _string(text: str) -> str:
    """A string literal holding `text`, the literal's raw content."""
    if "\n" in text or '"' in text:
        return f'"""{text}"""'
    return f'"{text}"'


def _constant(node: n.Constant) -> tuple[str, int]:
    value, raw = node.value, node.raw
    if isinstance(value, str):
        # A string's value is DECODED, so its raw is kept only while the node
        # still says what it said when read (`string_state`).
        if raw is not None and _unchanged(node):
            return raw, _ATOM
        return '"' + _encode(value) + '"', _ATOM
    if raw is not None and _denotes(raw, value):
        level = _UNARY if raw.startswith("-") else _ATOM
        return raw, level
    if value is None:
        return "null", _ATOM
    if isinstance(value, bool):
        return ("true" if value else "false"), _ATOM
    if isinstance(value, int):
        return str(value), (_UNARY if value < 0 else _ATOM)
    if isinstance(value, float):
        text = repr(value)
        if not any(c in text for c in ".e"):
            text += ".0"
        return text, (_UNARY if text.startswith("-") else _ATOM)
    raise ValueError(f"a Constant cannot hold {type(value).__name__}")


def _quantity(node: n.Quantity) -> str:
    """A unit literal: its `raw` when that still spells this magnitude and
    unit, else the two joined.

    ⚠ THE UNIT IS COMPARED UP TO COMPATIBILITY NORMALISATION, not by `==`.
    The lexer canonicalises a suffix -- `3_μs` (U+03BC, Greek mu) arrives
    with the unit `_µs` (U+00B5, micro sign), `LUNI.3.1_duration_sub_ms` --
    so a correct `raw` and the unit can differ in code points while naming
    one unit. Writing the canonical spelling would change the author's text
    and the next dump's `raw`."""
    raw = node.raw
    if raw is not None and raw.startswith(node.magnitude):
        suffix = raw[len(node.magnitude):]
        if unicodedata.normalize("NFKC", suffix) == \
                unicodedata.normalize("NFKC", node.unit):
            return raw
    return node.magnitude + node.unit


def _denotes(raw: str, value: Any) -> bool:
    """Whether the spelling `raw` still means `value`."""
    if value is None:
        return raw == "null"
    if isinstance(value, bool):
        return raw == ("true" if value else "false")
    try:
        if isinstance(value, int):
            return int(raw.replace("_", ""), 0) == value
        if isinstance(value, float):
            return float(raw.replace("_", "")) == value
    except ValueError:
        return False
    return False

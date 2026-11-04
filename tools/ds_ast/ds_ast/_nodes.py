"""GENERATED from tools/ds_ast/ds.asdl. Do not edit: regenerate it.

Schema sha256 (first 16): af29e1c6057eaf2f.
"""
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
from __future__ import annotations

from ._base import AST



class mod(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Module(mod):
    _fields = ('use', 'body', 'comments_end')
    _attributes = ()
    _field_kinds = {'use': '?', 'body': '*', 'comments_end': '*'}
    _field_types = {'use': 'use | None', 'body': 'list[decl]', 'comments_end': 'list[comment]'}
    __match_args__ = ('use', 'body', 'comments_end')


class use(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Use(use):
    _fields = ('dialect', 'settings')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'dialect': '', 'settings': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'dialect': 'str', 'settings': 'list[setting]'}
    __match_args__ = ('dialect', 'settings')


class setting(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Setting(setting):
    _fields = ('capability', 'value')
    _attributes = ()
    _field_kinds = {'capability': '', 'value': ''}
    _field_types = {'capability': 'str', 'value': 'bool'}
    __match_args__ = ('capability', 'value')


class decl(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Import(decl):
    _fields = ('path', 'asname')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'path': '*', 'asname': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'path': 'list[str]', 'asname': 'str | None'}
    __match_args__ = ('path', 'asname')


class ImportFrom(decl):
    _fields = ('path', 'names')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'path': '*', 'names': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'path': 'list[str]', 'names': 'list[alias]'}
    __match_args__ = ('path', 'names')


class Schema(decl):
    _fields = ('name', 'scope', 'docstring', 'slots')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'scope': '?', 'docstring': '?', 'slots': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'scope': 'scope | None', 'docstring': 'str | None', 'slots': 'list[slot]'}
    __match_args__ = ('name', 'scope', 'docstring', 'slots')


class Rule(decl):
    _fields = ('name', 'rate', 'docstring', 'lhs', 'lets', 'actions', 'afters')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'rate': '*', 'docstring': '?', 'lhs': '*', 'lets': '*', 'actions': '*', 'afters': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'rate': 'list[rate]', 'docstring': 'str | None', 'lhs': 'list[lhs]', 'lets': 'list[let]', 'actions': 'list[action]', 'afters': 'list[after]'}
    __match_args__ = ('name', 'rate', 'docstring', 'lhs', 'lets', 'actions', 'afters')


class Const(decl):
    _fields = ('name', 'annotation', 'value', 'colon_form')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'annotation': '?', 'value': '', 'colon_form': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'annotation': 'annotation | None', 'value': 'expr', 'colon_form': 'bool'}
    __match_args__ = ('name', 'annotation', 'value', 'colon_form')


class Series(decl):
    _fields = ('schema', 'slot', 'options', 'docstring', 'lines')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schema': '?', 'slot': '', 'options': '*', 'docstring': '?', 'lines': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schema': 'str | None', 'slot': 'str', 'options': 'list[series_option]', 'docstring': 'str | None', 'lines': 'list[series_line]'}
    __match_args__ = ('schema', 'slot', 'options', 'docstring', 'lines')


class Service(decl):
    _fields = ('name', 'docstring', 'kwargs', 'response', 'hydration')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '*', 'docstring': '?', 'kwargs': '*', 'response': '?', 'hydration': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'list[str]', 'docstring': 'str | None', 'kwargs': 'list[service_kwarg]', 'response': 'service_response | None', 'hydration': 'list[hydration_field]'}
    __match_args__ = ('name', 'docstring', 'kwargs', 'response', 'hydration')


class UnitDimension(decl):
    _fields = ('name', 'storage', 'base')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'storage': '', 'base': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'storage': 'str', 'base': 'str'}
    __match_args__ = ('name', 'storage', 'base')


class UnitScalar(decl):
    _fields = ('name', 'storage', 'label')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'storage': '', 'label': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'storage': 'str', 'label': 'str | None'}
    __match_args__ = ('name', 'storage', 'label')


class UnitSymbol(decl):
    _fields = ('symbol', 'dimension', 'body', 'label', 'aliases')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'symbol': '', 'dimension': '', 'body': '', 'label': '?', 'aliases': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'symbol': 'str', 'dimension': 'str', 'body': 'unit_body', 'label': 'str | None', 'aliases': 'list[str]'}
    __match_args__ = ('symbol', 'dimension', 'body', 'label', 'aliases')


class UnitFormula(decl):
    _fields = ('name', 'modifiers', 'lines')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'modifiers': '*', 'lines': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'modifiers': 'list[formula_modifier]', 'lines': 'list[formula_line]'}
    __match_args__ = ('name', 'modifiers', 'lines')


class UnitFxPair(decl):
    _fields = ('name', 'from_unit', 'to_unit', 'via', 'where', 'numerator', 'denominator')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'from_unit': '', 'to_unit': '', 'via': '', 'where': '', 'numerator': '', 'denominator': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'from_unit': 'str', 'to_unit': 'str', 'via': 'str', 'where': 'expr', 'numerator': 'str', 'denominator': 'str'}
    __match_args__ = ('name', 'from_unit', 'to_unit', 'via', 'where', 'numerator', 'denominator')


class Opaque(decl):
    _fields = ('name', 'representation')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'representation': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'representation': 'str'}
    __match_args__ = ('name', 'representation')


class Test(decl):
    _fields = ('name', 'sections')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'sections': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'expr', 'sections': 'list[test_section]'}
    __match_args__ = ('name', 'sections')


class InitialBlock(decl):
    _fields = ('items',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'items': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'items': 'list[initial_item]'}
    __match_args__ = ('items',)


class test_section(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Initial(test_section):
    _fields = ('items',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'items': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'items': 'list[initial_item]'}
    __match_args__ = ('items',)


class Inputs(test_section):
    _fields = ('blocks',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'blocks': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'blocks': 'list[at_block]'}
    __match_args__ = ('blocks',)


class Responses(test_section):
    _fields = ('stubs',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'stubs': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'stubs': 'list[stub]'}
    __match_args__ = ('stubs',)


class Produces(test_section):
    _fields = ('assertions',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'assertions': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'assertions': 'list[assertion]'}
    __match_args__ = ('assertions',)


class Until(test_section):
    _fields = ('when',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'when': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'when': 'expr'}
    __match_args__ = ('when',)


class initial_item(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class InitialFact(initial_item):
    _fields = ('fact',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'fact': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'fact': 'fact'}
    __match_args__ = ('fact',)


class CacheSeed(initial_item):
    _fields = ('key', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'key': '', 'value': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'key': 'expr', 'value': 'expr'}
    __match_args__ = ('key', 'value')


class CacheBlock(initial_item):
    _fields = ('seeds',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'seeds': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'seeds': 'list[seed]'}
    __match_args__ = ('seeds',)


class seed(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Seed(seed):
    _fields = ('key', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'key': '', 'value': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'key': 'expr', 'value': 'expr'}
    __match_args__ = ('key', 'value')


class fact(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Fact(fact):
    _fields = ('schema', 'args')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schema': '', 'args': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]'}
    __match_args__ = ('schema', 'args')


class at_block(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class At(at_block):
    _fields = ('when', 'facts')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'when': '', 'facts': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'when': 'expr', 'facts': 'list[fact]'}
    __match_args__ = ('when', 'facts')


class stub(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class ForCall(stub):
    _fields = ('library', 'service', 'args', 'correlation', 'after', 'replies')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'library': '*', 'service': '*', 'args': '*', 'correlation': '?', 'after': '?', 'replies': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'library': 'list[str]', 'service': 'list[str]', 'args': 'list[keyword]', 'correlation': 'expr | None', 'after': 'expr | None', 'replies': 'list[reply]'}
    __match_args__ = ('library', 'service', 'args', 'correlation', 'after', 'replies')


class reply(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Reply(reply):
    _fields = ('fact',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'fact': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'fact': 'fact'}
    __match_args__ = ('fact',)


class NoResponse(reply):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {}
    __match_args__ = ()


class assertion(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Assertion(assertion):
    _fields = ('never', 'head')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'never': '', 'head': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'never': 'bool', 'head': 'test_head'}
    __match_args__ = ('never', 'head')


class test_head(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Activated(test_head):
    _fields = ('rule',)
    _attributes = ()
    _field_kinds = {'rule': ''}
    _field_types = {'rule': 'str'}
    __match_args__ = ('rule',)


class Emitted(test_head):
    _fields = ('schema', 'args', 'binding', 'where')
    _attributes = ()
    _field_kinds = {'schema': '', 'args': '*', 'binding': '?', 'where': '?'}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]', 'binding': 'str | None', 'where': 'expr | None'}
    __match_args__ = ('schema', 'args', 'binding', 'where')


class Published(test_head):
    _fields = ('schema', 'args', 'binding', 'where')
    _attributes = ()
    _field_kinds = {'schema': '', 'args': '*', 'binding': '?', 'where': '?'}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]', 'binding': 'str | None', 'where': 'expr | None'}
    __match_args__ = ('schema', 'args', 'binding', 'where')


class Retracted(test_head):
    _fields = ('schema', 'args')
    _attributes = ()
    _field_kinds = {'schema': '', 'args': '*'}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]'}
    __match_args__ = ('schema', 'args')


class Recorded(test_head):
    _fields = ('kind',)
    _attributes = ()
    _field_kinds = {'kind': ''}
    _field_types = {'kind': 'str'}
    __match_args__ = ('kind',)


class Called(test_head):
    _fields = ('library', 'service', 'correlation')
    _attributes = ()
    _field_kinds = {'library': '*', 'service': '*', 'correlation': '?'}
    _field_types = {'library': 'list[str]', 'service': 'list[str]', 'correlation': 'expr | None'}
    __match_args__ = ('library', 'service', 'correlation')


class Cached(test_head):
    _fields = ('key', 'value')
    _attributes = ()
    _field_kinds = {'key': '', 'value': '?'}
    _field_types = {'key': 'expr', 'value': 'expr | None'}
    __match_args__ = ('key', 'value')


class CacheDeleted(test_head):
    _fields = ('key',)
    _attributes = ()
    _field_kinds = {'key': ''}
    _field_types = {'key': 'expr'}
    __match_args__ = ('key',)


class Logged(test_head):
    _fields = ('level', 'substring')
    _attributes = ()
    _field_kinds = {'level': '', 'substring': '?'}
    _field_types = {'level': 'log_level', 'substring': 'expr | None'}
    __match_args__ = ('level', 'substring')


class WmHas(test_head):
    _fields = ('schema', 'args')
    _attributes = ()
    _field_kinds = {'schema': '', 'args': '*'}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]'}
    __match_args__ = ('schema', 'args')


class WmCount(test_head):
    _fields = ('schema', 'count')
    _attributes = ()
    _field_kinds = {'schema': '', 'count': ''}
    _field_types = {'schema': 'type_ref', 'count': 'expr'}
    __match_args__ = ('schema', 'count')


class WmEmpty(test_head):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class alias(AST):
    _fields = ('name', 'asname')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'name': '', 'asname': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'name': 'str', 'asname': 'str | None'}
    __match_args__ = ('name', 'asname')


class comment(AST):
    _fields = ('text',)
    _attributes = ('lineno', 'col_offset', 'blank_lines_before')
    _field_kinds = {'text': '', 'lineno': '', 'col_offset': '', 'blank_lines_before': ''}
    _field_types = {'text': 'str'}
    __match_args__ = ('text',)


class service_response(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class ResponseSchema(service_response):
    _fields = ('name',)
    _attributes = ()
    _field_kinds = {'name': ''}
    _field_types = {'name': 'str'}
    __match_args__ = ('name',)


class NoServiceResponse(service_response):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class scope(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Explicit(scope):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Activation(scope):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Logical(scope):
    _fields = ('ambient',)
    _attributes = ()
    _field_kinds = {'ambient': ''}
    _field_types = {'ambient': 'bool'}
    __match_args__ = ('ambient',)


class Ttl(scope):
    _fields = ('duration', 'ambient')
    _attributes = ()
    _field_kinds = {'duration': '', 'ambient': ''}
    _field_types = {'duration': 'expr', 'ambient': 'bool'}
    __match_args__ = ('duration', 'ambient')


class Unprefixed(scope):
    _fields = ('scope',)
    _attributes = ()
    _field_kinds = {'scope': ''}
    _field_types = {'scope': 'scope'}
    __match_args__ = ('scope',)


class BareAmbient(scope):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class slot(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Slot(slot):
    _fields = ('name', 'type', 'nullable', 'capacity', 'markers', 'tolerance', 'docstring')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'type': '', 'nullable': '', 'capacity': '?', 'markers': '*', 'tolerance': '?', 'docstring': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'type': 'str', 'nullable': 'bool', 'capacity': 'expr | None', 'markers': 'list[marker]', 'tolerance': 'expr | None', 'docstring': 'str | None'}
    __match_args__ = ('name', 'type', 'nullable', 'capacity', 'markers', 'tolerance', 'docstring')


class marker(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}


class Key(marker):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}
    _field_types = {}
    __match_args__ = ()


class Mutable(marker):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}
    _field_types = {}
    __match_args__ = ()


class Sampled(marker):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}
    _field_types = {}
    __match_args__ = ()


class Retained(marker):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}
    _field_types = {}
    __match_args__ = ()


class rate(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}


class Cooldown(rate):
    _fields = ('duration',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'duration': '', 'lineno': '', 'col_offset': ''}
    _field_types = {'duration': 'expr'}
    __match_args__ = ('duration',)


class RateKey(rate):
    _fields = ('paths',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'paths': '*', 'lineno': '', 'col_offset': ''}
    _field_types = {'paths': 'list[expr]'}
    __match_args__ = ('paths',)


class lhs(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class PatternClause(lhs):
    _fields = ('pattern',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'pattern': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'pattern': 'pattern'}
    __match_args__ = ('pattern',)


class ThenClause(lhs):
    _fields = ('step',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'step': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'step': 'then_step'}
    __match_args__ = ('step',)


class pattern(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Simple(pattern):
    _fields = ('body',)
    _attributes = ()
    _field_kinds = {'body': ''}
    _field_types = {'body': 'pattern_body'}
    __match_args__ = ('body',)


class Negated(pattern):
    _fields = ('body', 'parenthesised')
    _attributes = ()
    _field_kinds = {'body': '', 'parenthesised': ''}
    _field_types = {'body': 'pattern_body', 'parenthesised': 'bool'}
    __match_args__ = ('body', 'parenthesised')


class Sequence(pattern):
    _fields = ('latest', 'head', 'steps')
    _attributes = ()
    _field_kinds = {'latest': '', 'head': '', 'steps': '*'}
    _field_types = {'latest': 'bool', 'head': 'pattern_body', 'steps': 'list[then_step]'}
    __match_args__ = ('latest', 'head', 'steps')


class pattern_body(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}


class PatternBody(pattern_body):
    _fields = ('type', 'binding', 'within', 'where', 'captures')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'type': '', 'binding': '?', 'within': '?', 'where': '?', 'captures': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'type': 'type_ref', 'binding': 'str | None', 'within': 'expr | None', 'where': 'expr | None', 'captures': 'list[str]'}
    __match_args__ = ('type', 'binding', 'within', 'where', 'captures')


class then_step(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}


class Then(then_step):
    _fields = ('latest', 'body', 'within')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'latest': '', 'body': '', 'within': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'latest': 'bool', 'body': 'pattern_body', 'within': 'expr'}
    __match_args__ = ('latest', 'body', 'within')


class type_ref(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class TypeName(type_ref):
    _fields = ('name',)
    _attributes = ()
    _field_kinds = {'name': ''}
    _field_types = {'name': 'str'}
    __match_args__ = ('name',)


class QualifiedType(type_ref):
    _fields = ('library', 'name')
    _attributes = ()
    _field_kinds = {'library': '*', 'name': ''}
    _field_types = {'library': 'list[str]', 'name': 'str'}
    __match_args__ = ('library', 'name')


class let(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Let(let):
    _fields = ('bindings',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'bindings': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'bindings': 'list[let_binding]'}
    __match_args__ = ('bindings',)


class let_binding(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class LetName(let_binding):
    _fields = ('name', 'annotation', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'annotation': '?', 'value': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'annotation': 'annotation | None', 'value': 'expr'}
    __match_args__ = ('name', 'annotation', 'value')


class LetCapture(let_binding):
    _fields = ('names', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'names': '*', 'value': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'names': 'list[str]', 'value': 'expr'}
    __match_args__ = ('names', 'value')


class annotation(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Annotation(annotation):
    _fields = ('type', 'nullable')
    _attributes = ()
    _field_kinds = {'type': '', 'nullable': ''}
    _field_types = {'type': 'str', 'nullable': 'bool'}
    __match_args__ = ('type', 'nullable')


class action(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Log(action):
    _fields = ('level', 'message', 'args')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'level': '', 'message': '', 'args': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'level': 'log_level', 'message': 'expr', 'args': 'list[keyword]'}
    __match_args__ = ('level', 'message', 'args')


class ServiceCall(action):
    _fields = ('library', 'service', 'args', 'block', 'continuations', 'correlation')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'library': '*', 'service': '*', 'args': '*', 'block': '*', 'continuations': '*', 'correlation': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'library': 'list[str]', 'service': 'list[str]', 'args': 'list[keyword]', 'block': 'list[keyword]', 'continuations': 'list[continuation]', 'correlation': 'expr | None'}
    __match_args__ = ('library', 'service', 'args', 'block', 'continuations', 'correlation')


class Emit(action):
    _fields = ('schema', 'args', 'block')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schema': '', 'args': '*', 'block': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]', 'block': 'list[keyword]'}
    __match_args__ = ('schema', 'args', 'block')


class Publish(action):
    _fields = ('schema', 'args', 'block')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schema': '', 'args': '*', 'block': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]', 'block': 'list[keyword]'}
    __match_args__ = ('schema', 'args', 'block')


class Cache(action):
    _fields = ('args', 'block')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'args': '*', 'block': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'args': 'list[keyword]', 'block': 'list[keyword]'}
    __match_args__ = ('args', 'block')


class CacheDelete(action):
    _fields = ('args', 'block')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'args': '*', 'block': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'args': 'list[keyword]', 'block': 'list[keyword]'}
    __match_args__ = ('args', 'block')


class RecordEvent(action):
    _fields = ('schema', 'args', 'block')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schema': '', 'args': '*', 'block': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schema': 'type_ref', 'args': 'list[keyword]', 'block': 'list[keyword]'}
    __match_args__ = ('schema', 'args', 'block')


class Withdraw(action):
    _fields = ('binding', 'args')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'binding': '', 'args': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'binding': 'str', 'args': 'list[keyword]'}
    __match_args__ = ('binding', 'args')


class log_level(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class LogDebug(log_level):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LogInfo(log_level):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LogWarning(log_level):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LogError(log_level):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LogCritical(log_level):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LogUnknown(log_level):
    _fields = ('written',)
    _attributes = ()
    _field_kinds = {'written': ''}
    _field_types = {'written': 'str'}
    __match_args__ = ('written',)


class keyword(AST):
    _fields = ('arg', 'value')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'arg': '', 'value': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'arg': 'str', 'value': 'expr | None'}
    __match_args__ = ('arg', 'value')


class continuation(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class OnResponse(continuation):
    _fields = ('test', 'body')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'test': '', 'body': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'test': 'expr', 'body': 'list[action]'}
    __match_args__ = ('test', 'body')


class OnTimeout(continuation):
    _fields = ('duration', 'body')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'duration': '', 'body': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'duration': 'expr', 'body': 'list[action]'}
    __match_args__ = ('duration', 'body')


class OnError(continuation):
    _fields = ('code', 'body')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'code': '*', 'body': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'code': 'list[str]', 'body': 'list[action]'}
    __match_args__ = ('code', 'body')


class after(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class After(after):
    _fields = ('duration', 'correlation', 'body', 'nested')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'duration': '', 'correlation': '?', 'body': '*', 'nested': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'duration': 'expr', 'correlation': 'expr | None', 'body': 'list[action]', 'nested': 'list[after]'}
    __match_args__ = ('duration', 'correlation', 'body', 'nested')


class series_option(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'lineno': '', 'col_offset': ''}


class Persist(series_option):
    _fields = ('duration',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'duration': '', 'lineno': '', 'col_offset': ''}
    _field_types = {'duration': 'expr'}
    __match_args__ = ('duration',)


class By(series_option):
    _fields = ('slot',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'slot': '?', 'lineno': '', 'col_offset': ''}
    _field_types = {'slot': 'str | None'}
    __match_args__ = ('slot',)


class Capacity(series_option):
    _fields = ('samples',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'samples': '', 'lineno': '', 'col_offset': ''}
    _field_types = {'samples': 'expr'}
    __match_args__ = ('samples',)


class Nulls(series_option):
    _fields = ('policy',)
    _attributes = ('lineno', 'col_offset')
    _field_kinds = {'policy': '', 'lineno': '', 'col_offset': ''}
    _field_types = {'policy': 'str'}
    __match_args__ = ('policy',)


class series_line(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class SeriesLine(series_line):
    _fields = ('aggregations', 'time', 'accuracy', 'gap', 'asname')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'aggregations': '*', 'time': '', 'accuracy': '?', 'gap': '?', 'asname': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'aggregations': 'list[str]', 'time': 'time_model', 'accuracy': 'accuracy | None', 'gap': 'gap_policy | None', 'asname': 'str | None'}
    __match_args__ = ('aggregations', 'time', 'accuracy', 'gap', 'asname')


class time_model(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class AllTime(time_model):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Sliding(time_model):
    _fields = ('window',)
    _attributes = ()
    _field_kinds = {'window': ''}
    _field_types = {'window': 'expr'}
    __match_args__ = ('window',)


class Tumbling(time_model):
    _fields = ('window',)
    _attributes = ()
    _field_kinds = {'window': ''}
    _field_types = {'window': 'expr'}
    __match_args__ = ('window',)


class Sample(time_model):
    _fields = ('size',)
    _attributes = ()
    _field_kinds = {'size': ''}
    _field_types = {'size': 'expr'}
    __match_args__ = ('size',)


class accuracy(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Exact(accuracy):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Tolerance(accuracy):
    _fields = ('value',)
    _attributes = ()
    _field_kinds = {'value': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class Confidence(accuracy):
    _fields = ('value',)
    _attributes = ()
    _field_kinds = {'value': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class Delta(accuracy):
    _fields = ('value',)
    _attributes = ()
    _field_kinds = {'value': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class BoundDeterministic(accuracy):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class gap_policy(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class GapHold(gap_policy):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class GapZero(gap_policy):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class GapSkip(gap_policy):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class service_kwarg(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class ServiceKwarg(service_kwarg):
    _fields = ('name', 'type', 'modifiers')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'type': '', 'modifiers': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'type': 'str', 'modifiers': 'list[kwarg_modifier]'}
    __match_args__ = ('name', 'type', 'modifiers')


class kwarg_modifier(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Default(kwarg_modifier):
    _fields = ('value',)
    _attributes = ()
    _field_kinds = {'value': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class Literal(kwarg_modifier):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Required(kwarg_modifier):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class hydration_field(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class Hydrates(hydration_field):
    _fields = ('schemas',)
    _attributes = ('lineno', 'col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'schemas': '*', 'lineno': '', 'col_offset': '', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'schemas': 'list[str]'}
    __match_args__ = ('schemas',)


class MaxWindow(hydration_field):
    _fields = ('value',)
    _attributes = ('lineno', 'col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'value': '', 'lineno': '', 'col_offset': '', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class MaxLimit(hydration_field):
    _fields = ('value',)
    _attributes = ('lineno', 'col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'value': '', 'lineno': '', 'col_offset': '', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'value': 'expr'}
    __match_args__ = ('value',)


class FilterFields(hydration_field):
    _fields = ('fields',)
    _attributes = ('lineno', 'col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'fields': '*', 'lineno': '', 'col_offset': '', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'fields': 'list[filter_field]'}
    __match_args__ = ('fields',)


class filter_field(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class FilterField(filter_field):
    _fields = ('name', 'ops')
    _attributes = ()
    _field_kinds = {'name': '', 'ops': '*'}
    _field_types = {'name': 'str', 'ops': 'list[cmpop]'}
    __match_args__ = ('name', 'ops')


class unit_body(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class BaseUnit(unit_body):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Affine(unit_body):
    _fields = ('expr',)
    _attributes = ()
    _field_kinds = {'expr': ''}
    _field_types = {'expr': 'expr'}
    __match_args__ = ('expr',)


class Tier2(unit_body):
    _fields = ('to_base', 'from_base')
    _attributes = ()
    _field_kinds = {'to_base': '', 'from_base': ''}
    _field_types = {'to_base': 'expr', 'from_base': 'expr'}
    __match_args__ = ('to_base', 'from_base')


class formula_modifier(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Inverting(formula_modifier):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Implicit(formula_modifier):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class formula_line(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}


class FormulaLine(formula_line):
    _fields = ('name', 'param', 'param_type', 'returns', 'body')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset', 'comments_before', 'comment_after', 'blank_lines_before')
    _field_kinds = {'name': '', 'param': '', 'param_type': '', 'returns': '', 'body': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?', 'comments_before': '*', 'comment_after': '?', 'blank_lines_before': ''}
    _field_types = {'name': 'str', 'param': 'str', 'param_type': 'str', 'returns': 'str', 'body': 'expr'}
    __match_args__ = ('name', 'param', 'param_type', 'returns', 'body')


class expr(AST):
    _fields = ()
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}


class BoolOp(expr):
    _fields = ('op', 'values')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'op': '', 'values': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'op': 'boolop', 'values': 'list[expr]'}
    __match_args__ = ('op', 'values')


class UnaryOp(expr):
    _fields = ('op', 'operand')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'op': '', 'operand': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'op': 'unaryop', 'operand': 'expr'}
    __match_args__ = ('op', 'operand')


class BinOp(expr):
    _fields = ('left', 'op', 'right')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'left': '', 'op': '', 'right': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'left': 'expr', 'op': 'operator', 'right': 'expr'}
    __match_args__ = ('left', 'op', 'right')


class Compare(expr):
    _fields = ('left', 'ops', 'comparators')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'left': '', 'ops': '*', 'comparators': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'left': 'expr', 'ops': 'list[cmpop]', 'comparators': 'list[expr]'}
    __match_args__ = ('left', 'ops', 'comparators')


class Is(expr):
    _fields = ('operand', 'negated', 'subject')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'operand': '', 'negated': '', 'subject': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'operand': 'expr', 'negated': 'bool', 'subject': 'is_subject'}
    __match_args__ = ('operand', 'negated', 'subject')


class Match(expr):
    _fields = ('operand', 'negated', 'pattern', 'flags')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'operand': '', 'negated': '', 'pattern': '', 'flags': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'operand': 'expr', 'negated': 'bool', 'pattern': 'str', 'flags': 'str'}
    __match_args__ = ('operand', 'negated', 'pattern', 'flags')


class Call(expr):
    _fields = ('func', 'args')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'func': '', 'args': '*', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'func': 'expr', 'args': 'list[expr]'}
    __match_args__ = ('func', 'args')


class Cast(expr):
    _fields = ('operand', 'type', 'nullable')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'operand': '', 'type': '', 'nullable': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'operand': 'expr', 'type': 'str', 'nullable': 'bool'}
    __match_args__ = ('operand', 'type', 'nullable')


class Attribute(expr):
    _fields = ('value', 'attr')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'value': '', 'attr': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'value': 'expr', 'attr': 'str'}
    __match_args__ = ('value', 'attr')


class Subscript(expr):
    _fields = ('value', 'index')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'value': '', 'index': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'value': 'expr', 'index': 'expr'}
    __match_args__ = ('value', 'index')


class Name(expr):
    _fields = ('id',)
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'id': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'id': 'str'}
    __match_args__ = ('id',)


class QualifiedName(expr):
    _fields = ('library', 'id')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'library': '*', 'id': '', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'library': 'list[str]', 'id': 'str'}
    __match_args__ = ('library', 'id')


class Constant(expr):
    _fields = ('value', 'raw')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'value': '', 'raw': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'value': 'object', 'raw': 'str | None'}
    __match_args__ = ('value', 'raw')


class Quantity(expr):
    _fields = ('magnitude', 'unit', 'raw')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'magnitude': '', 'unit': '', 'raw': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'magnitude': 'str', 'unit': 'str', 'raw': 'str | None'}
    __match_args__ = ('magnitude', 'unit', 'raw')


class JoinedStr(expr):
    _fields = ('values', 'raw')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'values': '*', 'raw': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'values': 'list[expr]', 'raw': 'str | None'}
    __match_args__ = ('values', 'raw')


class FormattedValue(expr):
    _fields = ('value', 'format_spec')
    _attributes = ('lineno', 'col_offset', 'end_lineno', 'end_col_offset')
    _field_kinds = {'value': '', 'format_spec': '?', 'lineno': '', 'col_offset': '', 'end_lineno': '?', 'end_col_offset': '?'}
    _field_types = {'value': 'expr', 'format_spec': 'str | None'}
    __match_args__ = ('value', 'format_spec')


class boolop(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class And(boolop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Or(boolop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class operator(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Add(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Sub(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Mult(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Div(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class FloorDiv(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Mod(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Pow(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class BitOr(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class BitXor(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class BitAnd(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LShift(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class RShift(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Coalesce(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class In(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Contains(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Overlaps(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Range(operator):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class unaryop(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Not(unaryop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class UAdd(unaryop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class USub(unaryop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Invert(unaryop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class cmpop(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class Eq(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class NotEq(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Lt(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class LtE(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class Gt(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class GtE(cmpop):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class is_subject(AST):
    _fields = ()
    _attributes = ()
    _field_kinds = {}


class IsNull(is_subject):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class IsBool(is_subject):
    _fields = ('value',)
    _attributes = ()
    _field_kinds = {'value': ''}
    _field_types = {'value': 'bool'}
    __match_args__ = ('value',)


class IsInf(is_subject):
    _fields = ('negative',)
    _attributes = ()
    _field_kinds = {'negative': ''}
    _field_types = {'negative': 'bool'}
    __match_args__ = ('negative',)


class IsNaN(is_subject):
    _fields = ()
    _attributes = ()
    _field_kinds = {}
    _field_types = {}
    __match_args__ = ()


class IsTag(is_subject):
    _fields = ('tag',)
    _attributes = ()
    _field_kinds = {'tag': ''}
    _field_types = {'tag': 'str'}
    __match_args__ = ('tag',)


__all__ = ['mod', 'Module', 'use', 'Use', 'setting', 'Setting', 'decl', 'Import', 'ImportFrom', 'Schema', 'Rule', 'Const', 'Series', 'Service', 'UnitDimension', 'UnitScalar', 'UnitSymbol', 'UnitFormula', 'UnitFxPair', 'Opaque', 'Test', 'InitialBlock', 'test_section', 'Initial', 'Inputs', 'Responses', 'Produces', 'Until', 'initial_item', 'InitialFact', 'CacheSeed', 'CacheBlock', 'seed', 'Seed', 'fact', 'Fact', 'at_block', 'At', 'stub', 'ForCall', 'reply', 'Reply', 'NoResponse', 'assertion', 'Assertion', 'test_head', 'Activated', 'Emitted', 'Published', 'Retracted', 'Recorded', 'Called', 'Cached', 'CacheDeleted', 'Logged', 'WmHas', 'WmCount', 'WmEmpty', 'alias', 'comment', 'service_response', 'ResponseSchema', 'NoServiceResponse', 'scope', 'Explicit', 'Activation', 'Logical', 'Ttl', 'Unprefixed', 'BareAmbient', 'slot', 'Slot', 'marker', 'Key', 'Mutable', 'Sampled', 'Retained', 'rate', 'Cooldown', 'RateKey', 'lhs', 'PatternClause', 'ThenClause', 'pattern', 'Simple', 'Negated', 'Sequence', 'pattern_body', 'PatternBody', 'then_step', 'Then', 'type_ref', 'TypeName', 'QualifiedType', 'let', 'Let', 'let_binding', 'LetName', 'LetCapture', 'annotation', 'Annotation', 'action', 'Log', 'ServiceCall', 'Emit', 'Publish', 'Cache', 'CacheDelete', 'RecordEvent', 'Withdraw', 'log_level', 'LogDebug', 'LogInfo', 'LogWarning', 'LogError', 'LogCritical', 'LogUnknown', 'keyword', 'continuation', 'OnResponse', 'OnTimeout', 'OnError', 'after', 'After', 'series_option', 'Persist', 'By', 'Capacity', 'Nulls', 'series_line', 'SeriesLine', 'time_model', 'AllTime', 'Sliding', 'Tumbling', 'Sample', 'accuracy', 'Exact', 'Tolerance', 'Confidence', 'Delta', 'BoundDeterministic', 'gap_policy', 'GapHold', 'GapZero', 'GapSkip', 'service_kwarg', 'ServiceKwarg', 'kwarg_modifier', 'Default', 'Literal', 'Required', 'hydration_field', 'Hydrates', 'MaxWindow', 'MaxLimit', 'FilterFields', 'filter_field', 'FilterField', 'unit_body', 'BaseUnit', 'Affine', 'Tier2', 'formula_modifier', 'Inverting', 'Implicit', 'formula_line', 'FormulaLine', 'expr', 'BoolOp', 'UnaryOp', 'BinOp', 'Compare', 'Is', 'Match', 'Call', 'Cast', 'Attribute', 'Subscript', 'Name', 'QualifiedName', 'Constant', 'Quantity', 'JoinedStr', 'FormattedValue', 'boolop', 'And', 'Or', 'operator', 'Add', 'Sub', 'Mult', 'Div', 'FloorDiv', 'Mod', 'Pow', 'BitOr', 'BitXor', 'BitAnd', 'LShift', 'RShift', 'Coalesce', 'In', 'Contains', 'Overlaps', 'Range', 'unaryop', 'Not', 'UAdd', 'USub', 'Invert', 'cmpop', 'Eq', 'NotEq', 'Lt', 'LtE', 'Gt', 'GtE', 'is_subject', 'IsNull', 'IsBool', 'IsInf', 'IsNaN', 'IsTag']

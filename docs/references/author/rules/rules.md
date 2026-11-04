<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Rules

## Declaration

### `rule`

**`rule_decl ::= 'rule' NAME rule_modifier* ':' NEWLINE INDENT docstring? pattern+ DEDENT '->' NEWLINE INDENT let_decl* action_body DEDENT`**

A top-level declaration of [patterns](patterns.md), then, after `->`, [`let` bindings](let.md) and [actions](../actions/actions.md#action).

The patterns sit at column 4. They dedent to column 0 for `->`, and the right-hand side indents after it.

```ds rule
rule high_level:
    Reading r where r.level > 10.0
->
    log info "high {r.id}"
```

*(Spec: [LGRA.6.1], [LGRA.6.2])*

### Docstring

A bare string as the first line of the rule body, after the header and before the first pattern, is the rule docstring, in either string form.

*(Spec: [LGRA.6.5])*

### Rule name

A rule name is unique in its compilation unit: the file being compiled and every library in its import graph. Names compare as identifiers do. A duplicate is refused with `DS_VALIDATE_DUPLICATE_RULE`, naming both declarations.

Every library rule compiles into the importer's artefact, whatever the import took.

*(Spec: [LGRA.6.8])*

## Header modifiers

**`rule_modifier ::= rate_mod | rate_key`**

The modifiers stand between the rule name and the `:`. They are `cooldown` and `by:`, at [Cooldown](cooldown.md).

*(Spec: [LGRA.6.1], [LGRA.6.6.1], [LGRA.6.6.2], [LCDB.5.1])*

## Refraction

An activation whose rule and matched facts have already fired is not eligible to fire again until its left-hand side changes. It is removed from consideration, not ordered later.

[The clock moving on](../time/types.md#edge-firing) is no change to the left-hand side.

*(Spec: [LDET.5.3], [LDET.5.8])*

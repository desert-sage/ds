<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Cooldown

## The modifier

### `cooldown`

**`rate_mod ::= 'cooldown' time_expr`**

When an activation fires, suppresses further fires of the same activation key for the duration. The duration's forms are at [Duration positions](../units/literals.md#duration-positions).

The gate is on the right-hand side. The rule still activates on every matching left-hand side, and the activation key is computed each time. A suppressed activation has its right-hand side skipped, and counts as fired for refraction.

Cooldown state does not survive an engine restart. Cooldown suppresses firing across pumps, and the [total order](firing-order.md#total-order) orders firing within one.

A call's own rate is at [`cooldown` on a call](../calls/call.md#cooldown-on-a-call).

```ds rule
rule limited cooldown 5_min:
    Reading r where r.level > 10.0
->
    log info "high {r.id}"
```

*(Spec: [LCDB.3.1], [LCDB.3.2.1], [LCDB.3.2.1.1], [LCDB.7.3], [LCDB.7.5], [LGRA.6.1], [LGRA.6.6.2])*

### Duration refusals

| Condition | Code |
|---|---|
| a negative duration | `DS_VALIDATE_RATE_NEGATIVE_DURATION` |
| a second `cooldown` on one rule | `DS_PARSE_DUP_RATE_MOD` |

`cooldown 0_s` is legal and has no effect.

```ds rule error=DS_VALIDATE_RATE_NEGATIVE_DURATION
rule negative cooldown -5_min:
    Reading r where r.ok
->
    log info "never"
```

*(Spec: [LGRA.6.6.7], [LCDB.5.3], [LCDB.5.5], [LCDB.5.6], [LCDB.7.8])*

## The activation key

### Default key

The key is the ordered concatenation, per bound pattern in source order, of each fact's contributing slots:

- a `logical` fact contributes its declared [`key` slots](../facts/schemas.md#key-and-mutable), and a schema with none contributes nothing;
- a fact of any other lifecycle contributes nothing.

Suppression is keyed on the rule and its activation key, so one rule matching different keys cools independently, and a change to a `mutable` slot does not reset it.

*(Spec: [LCDB.3.3.1], [LCDB.3.3.3], [LCDB.7.1], [LCDB.7.2])*

### `by:`

**`rate_key ::= 'by' ':' ( key_path (',' key_path)* | 'none' )`**

**`key_path ::= NAME '.' NAME`**

Declares the activation key in place of the default: an ordered tuple of `<binding>.<slot>` paths, or the one global key `by: none`.

A rule with a rate modifier that binds, in a positive pattern, a fact of a lifecycle other than `logical` requires it.

| Condition | Code |
|---|---|
| no `by:` where one is required | `DS_VALIDATE_RATE_KEY_REQUIRED` |
| a path naming an undeclared binding, or a slot its schema does not have | `DS_VALIDATE_RATE_KEY_BAD_PATH` |

```ds rule
rule by_label cooldown 5_min by: r.label:
    Reading r where r.ok
->
    log info "{r.label}"
```

*(Spec: [LGRA.6.1], [LCDB.3.3.4], [LCDB.5.1])*

### Empty key

With an empty key, the rule has one window for all its activations. The compiler warns with `DS_VALIDATE_RULE_WIDE_RATE_WINDOW`, naming the rule, and the program compiles.

*(Spec: [LCDB.3.3.3], [LCDB.7.2], [LCDB.7.9])*

## On-delay

A rule that fires only once a match has held for `T` states `where x.dwell >= T` on a `logical` binding, with [`dwell`](../facts/logical.md#dwell). The condition is [re-evaluated on every pump](../time/types.md#re-evaluation), and the rule fires on the pump at which it first holds. If the fact is retracted or replaced first, the match ends and nothing fires.

```ds rule
rule held:
    Reading r where r.dwell >= 30_s
->
    log info "{r.id}"
```

*(Spec: [LCDB.3.1], [LCDB.3.2.3])*

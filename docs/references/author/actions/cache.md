<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Cache

## Write

### `cache`

**`cache key: <key> value: <value> [ttl: <duration>]`**

`cache` writes a value under a key in the mutable key-value store.

Values are opaque to the engine: it does not version or inspect them, and no rule matches on a cache change. The key is a [cache key](#cache-key). A superseding write replaces the value.

A non-finite `Float` in `value:` is [a trap at the verb](../expr/math.md#nan-values): the activation is abandoned at the write, and the cache is untouched.

```ds action
cache key: "limit" value: r.level ttl: 1_h
```

*(Spec: [LSTO.4.1], [LSTO.4.2.1], [LSTO.4.7.3], [LSTO.9.5], [LGRA.10.3.3], [LDET.3.2.7], [LEXP.4.2])*

### `cache_delete`

**`cache_delete key: <key>`**

`cache_delete` invalidates a key.

```ds action
log info "{r.id}"
cache_delete key: "limit"
```

*(Spec: [LSTO.4.4.1], [LGRA.10.3.3])*

### Cache key

The `key:` of `cache` or `cache_delete` is a `STRING_LIT` with no interpolation site.

Any other value is refused with `DS_VALIDATE_DYNAMIC_IDENT_KWARG`. `value:` and `ttl:` take any expression the context allows.

```ds action error=DS_VALIDATE_DYNAMIC_IDENT_KWARG
cache key: r.label value: 1
```

*(Spec: [LGRA.10.3.7])*

## Read

### `cached`

**`cached("<key>")`**

`cached` reads a key synchronously and inline, in the same activation; a miss is `null`.

It is the entire right-hand side of a `let`, or inside a `where`; anywhere else is a compile error. A `let` binds it once per activation at the start of the actions. A `where` on a rule with more than one positive pattern refuses it, as [`where` on a join](../expr/operators.md#where-on-a-join) states.

```ds action
let held = cached("limit")
log info "{r.id} {held}"
```

*(Spec: [LSTO.4.1], [LSTO.4.3.1], [LSTO.4.3.1a], [LSTO.4.3.1b], [LSTO.5.1], [LSTO.9.7], [LGRA.9.8.2], [LGRA.9.8.4])*

### `cached` in a `where`

**`<pattern> where <test over cached("<key>")>`**

The cache is read-only while patterns are evaluated, and its value is stable for a single activation's `where` evaluation.

The key may be interpolated, under [Eligible positions](actions.md#eligible-positions). A miss propagates `null` through a comparison; `cached(...) is null` is the test that catches it.

```ds rule
rule changed:
    Reading r where r.n != cached("rev") or cached("rev") is null
->
    log info "{r.id}"
```

*(Spec: [LSTO.4.3.1a], [LSTO.4.3.1b], [LNUL.4.4])*

## Loss

### Within a session

A written key stays readable until `cache_delete`, a superseding write, or its TTL.

A `cache` write does not silently drop.

*(Spec: [LSTO.4.5.1], [LSTO.6.2], [LSTO.9.6])*

### Across a restart

The cache cold-starts empty on a restart, unless the integrator persists it and seeds it at startup.

The integrator's part is [Cache](inv:integrator:std:doc#callbacks/cache). A pre-restart key absent after a restart reads as `null`.

*(Spec: [LSTO.4.3.2], [LSTO.4.5.2], [LSTO.6.2])*

## TTL

### Key TTL

`ttl: <duration>` on `cache` sets a per-write expiry, and an expired key reads as not found.

A read that meets an expired entry removes it, and the removal fires the integrator's removal callback, at [Cache](inv:integrator:std:doc#callbacks/cache).

*(Spec: [LSTO.4.6.1], [LSTO.4.3.3])*

### Cache bounds

An integrator may bound the cache by its live keys and by its values' total bytes; neither is set by default, and a bound evicts nothing.

A write past a bound is a bounds refusal. The write is not performed, and the firing stops there: the actions before it stand, the actions after it do not run. The pump goes on, and a later `cached` reads the cache as it was.

*(Spec: [LSTO.4.6.1], [LSTO.4.7.5])*

## Ownership

### Engine state

The engine owns the cache: every key's authoritative value is engine state, held beside working memory.

Only `cache`, `cache_delete`, a key's TTL expiring, the integrator's startup seed and an [`initial` block's cache item](../facts/initial.md#cache-items) mutate it. `cache` and `cache_delete` are synchronous engine-local writes, and each tier's engine owns its own cache.

*(Spec: [LSTO.4.7.1], [LSTO.4.7.2], [LSTO.4.7.4], [LSTO.4.6.1], [LSTO.5.1], [LTIE.1.7], [LTIE.5.2], [LGRA.24.3])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Imports

## Import forms

### `import`

**`'import' NAME ('.' NAME)* ('as' NAME)?`**

Binds the library's path, or its `as` alias, in the importing file. Each exported name is reached as `path.name`.

A bare name of the library does not resolve without a selective import. A qualified reference in a type position to a library the file does not import is refused with `DS_VALIDATE_UNKNOWN_QUALIFIER`; in expression position it is unresolved ([Dotted names](program.md#dotted-names)).

```ds expression head
import math
math.sqrt(r.level)
```

*(Spec: [LIMP.1.1], [LIMP.2.1.1], [LIMP.2.1.2], [LIMP.4.1.1], [LIMP.4.1.2])*

### `from`

**`'from' NAME ('.' NAME)* 'import' import_list`**

**`import_item ::= NAME ('as' NAME)?`**

Binds each listed name bare in the importing file, under its `as` alias where one is given. Each is a single identifier: a dotted item is a compile error, and `*` a parse error.

The list is flat, or parenthesised to span lines. A trailing comma is admitted in both. A name listed twice is one binding.

```ds expression head
from math import sqrt as root, floor
floor(root(r.level))
```

*(Spec: [LIMP.2.1.1], [LIMP.2.1.3], [LIMP.2.2.1], [LIMP.2.2.2], [LIMP.2.4.2], [LIMP.4.2.1], [LIMP.4.2.2], [LIMP.4.2.4], [LIMP.5.2.2])*

### Both forms together

`import plant.sensors` with `from plant.sensors import Reading` puts `plant.sensors.Reading` and `Reading` in scope, both resolving to one declaration.

*(Spec: [LIMP.4.2.3])*

### `as`

Renames the imported name in the importing file. An alias stands for the library's path in a `lib.Schema` reference. An alias changes no [own name](#own-name).

*(Spec: [LIMP.2.1.7], [LIMP.13.2])*

## Placement

Imports follow any `use` and precede every other top-level declaration, at file top level.

| Refused | Code |
|---|---|
| an import after a non-import top-level declaration | `DS_VALIDATE_IMPORT_AFTER_DECL` |
| an import before `use` | `DS_VALIDATE_IMPORT_BEFORE_USE` |

```ds declaration error=DS_VALIDATE_IMPORT_AFTER_DECL
import math
```

*(Spec: [LIMP.2.3.1], [LIMP.2.3.2], [LIMP.2.3.3], [LIMP.2.4.4], [LGRA.3.1])*

## Resolution

### Search path

The compiler resolves a library path to one `.ds` file through the search path or file list of its invocation. The language fixes no environment variable or layout. The bundled standard library is one entry, after every entry the invocation names, and is always present.

An import names a library and nothing else. The compiler reads the file that resolves. A library file has the grammar of a rule file, and [a `use` directive separates the two](../capabilities/dialects.md#programs-and-libraries).

*(Spec: [LIMP.1.3], [LIMP.3.1.1], [LIMP.3.3.1], [LIMP.8.1.1], [LIMP.8.1.2], [LIMP.10.5])*

### Dotted paths

**`import a.b.c`**

Segments are directory names and the final segment is the file name: for a search-path entry `<root>`, the candidate is `<root>/a/b/c.ds`. Entries are checked in order, and the first match wins. A file `<root>/a.b.ds` does not match `import a.b`.

Each segment is a `NAME`. Path depth has no limit. `import units` needs `units.ds`, whether or not `units/si.ds` exists.

*(Spec: [LIMP.2.1.4], [LIMP.2.1.5], [LIMP.2.1.6], [LIMP.2.4.3], [LIMP.3.1.4], [LIMP.3.1.5], [LIMP.3.1.6])*

### Resolution refusals

| Condition | Code |
|---|---|
| no `.ds` file resolves | `DS_VALIDATE_UNKNOWN_LIBRARY` |
| several `.ds` files resolve | `DS_VALIDATE_AMBIGUOUS_LIBRARY` |
| the file resolves and does not parse, reported at the `import` line with the parse failure in the message | `DS_VALIDATE_LIBRARY_PARSE_FAILED` |

*(Spec: [LIMP.3.1.2], [LIMP.3.1.3], [LIMP.3.1.7])*

## Scope

### File scope

Every name a file's declarations use resolves against what that file declares, what its own imports bind, and what is in scope in every file. An importer's declarations, imports and aliases take no part.

A file reading a slot takes the type the declaring file gave it, whether or not the reading file can name that type.

A library is validated under the importing program's settings.

*(Spec: [LIMP.1.5], [LDIA.2.10.9])*

### No implicit library

No library is imported implicitly. The cache verbs `cache`, `cache_delete` and `cached(...)` are language primitives and need no import.

*(Spec: [LIMP.3.3.2], [LIMP.3.3.3], [LIMP.9.7])*

### `math`, `distance` and `calendar`

Each of these standard library modules carries builtin functions as members, and no other library or author module does. A member is reached only through an import of its module: `math.sin` after `import math`, `sin` after `from math import sin`. A member's name is no reserved word.

A call of a member that no import reaches is refused with `DS_VALIDATE_UNKNOWN_FUNCTION`.

The members are at [`math`](../expr/math.md), [`distance`](../expr/distance.md) and [`calendar`](../time/calendar.md).

```ds expression error=DS_VALIDATE_UNKNOWN_FUNCTION
sin(r.level)
```

*(Spec: [LIMP.3.3.4])*

### Internal names

A library identifier that starts with `_` is reachable inside that file and takes no part in import resolution. External references get the diagnostic of any unknown name:

| Reference | Code |
|---|---|
| `from plant.sensors import _helper` | `DS_VALIDATE_UNKNOWN_IMPORT_NAME` |
| `plant.sensors._helper` in expression position | `DS_VALIDATE_UNKNOWN_QUALIFIED_CONST` |
| `plant.sensors._Helper` in pattern position | `DS_VALIDATE_UNKNOWN_SCHEMA` |

*(Spec: [LIMP.4.3.1], [LIMP.4.3.2], [LIMP.4.3.4], [LIMP.9.9])*

### Re-export

`from B import X` in library A makes `X` part of A's top-level declarations: an importer of A reaches it as `A.X`, or bare through `from A import X`. A bare `import B` in A makes B reachable in A's source only.

*(Spec: [LIMP.4.4.1], [LIMP.4.4.2], [LIMP.1.5])*

## What is importable

A library's importable names are its top-level declarations whose names do not start with `_`: `schema`, `const`, `rule`, `unit` and `unit formula` declarations, flat-named `service` declarations, and domains.

- A domain is the first segment of a dotted service name. Importing it brings the whole `<domain>.*` service set into bare scope.
- A formula is imported by its formula name, which brings both its functions. A function name alone is not importable.
- A service's own name stays dotted, and a call names it bare, whichever form imported the declaring library. No library qualifier applies to a service.

A name the library does not declare at top level is refused with `DS_VALIDATE_UNKNOWN_IMPORT_NAME`, at the import line.

*(Spec: [LIMP.4.1.1], [LIMP.4.2.4], [LIMP.4.2.6], [LIMP.7.1], [LIMP.7.2], [LIMP.7.3], [LIMP.7.4], [LIMP.7.5], [LIMP.7.7])*

## Conflicts

| Condition | Code |
|---|---|
| two distinct schemas in scope under one NFC name with no alias | `DS_VALIDATE_IMPORT_NAME_COLLISION` |
| a unit imported by name from two different libraries, even with the same conversion | `DS_VALIDATE_UNIT_IMPORT_COLLISION` |
| a local `unit` naming a base unit or alias of `units.core` | `DS_VALIDATE_UNIT_IMPORT_COLLISION` |
| a local `unit` whose name the file imports | `DS_VALIDATE_UNIT_LOCAL_SHADOWS_IMPORT` |

The schema check is by schema identity: one schema re-exported through two paths does not collide. The library-qualified form distinguishes two schemas without an alias.

Import order never chooses between two units: the unit refusals apply at the second binding.

Two libraries in one compilation that declare a service of one name collide, and the compiler refuses the program.

*(Spec: [LGRA.22.5], [LIMP.2.1.7], [LIMP.5.1.5], [LIMP.5.3.1])*

## Import cycles

The import graph's nodes are library files and the compiled file, and its edges are `import` and `from ... import` statements. A cycle is refused with `DS_VALIDATE_IMPORT_CYCLE`, which reports the cycle path.

*(Spec: [LIMP.6.1], [LIMP.9.11])*

## Own name

Every schema has one own name:

| Declared in | Own name |
|---|---|
| the file being compiled | its `NAME` |
| a library | the library's dotted import path, a `.`, and its `NAME`: `plant.sensors.Reading` |
| the built-in module | its `NAME` |

The path is the one [dotted-path resolution](#dotted-paths) resolves, never an `as` alias, a search-path entry or a file path. A re-exported schema keeps the own name of the library that declares it.

An artefact, a recording and a host name a schema by its own name. An `as` alias and a `lib.Schema` reference are spellings in one source file.

A fact crosses between tiers only where each holds a schema of that own name: each imports one library under one path, or each declares the `NAME` in the file it compiles. A `Reply` one program declares and a `lib.Reply` another imports are two schemas, and the receiver refuses the record.

*(Spec: [LIMP.13.1], [LIMP.13.2], [LIMP.13.3])*

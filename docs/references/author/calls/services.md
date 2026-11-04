<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Services

## Declaration

### `service`

```text
service_decl    ::= 'service' service_name ':' NEWLINE
                    INDENT
                        docstring?
                        kwarg_decl*
                        response_decl
                    DEDENT

service_name    ::= NAME ('.' NAME)*

kwarg_decl      ::= 'kwarg' NAME ':' TYPE_SYM kwarg_modifier* NEWLINE
kwarg_modifier  ::= 'default' '-'? literal
                 |  'literal'
                 |  'required'

response_decl   ::= 'response' TYPE_SYM NEWLINE
                 |  'no' 'response' NEWLINE
```

A `service` declaration names what a [`call`](call.md#call) reaches, its kwargs and its answer.

```ds declaration
service svc.ping:
    kwarg n: Int required
    no response
```

*(Spec: [LGRA.23.1])*

### Kwarg declarations

Kwargs are written in any order, and each modifier in any order, at most once.

A repeated modifier is refused with `DS_PARSE_KWARG_MODIFIER_DUPLICATE`.

`TYPE_SYM` resolves in the [type namespace](../lang/program.md#type-namespace): a scalar builtin, a unit symbol, a dimension or scalar-group name, a schema, the kind `Schema`, or an opaque type, which an argument matches exactly. Any other is refused with `DS_VALIDATE_UNKNOWN_TYPE`. A kwarg declared with a schema or with `Schema` takes only a pattern binding; any other argument is refused with `DS_VALIDATE_FACT_KWARG_NOT_BINDING`.

*(Spec: [LGRA.23.2])*

### Kwarg modifiers

**`required`**, **`literal`**, **`default`**

A kwarg's modifiers constrain every `call` to the service.

| Modifier | At a call |
|---|---|
| `required` | omitting the kwarg is refused with `DS_VALIDATE_MISSING_KWARG` |
| `literal` | [Dynamic and literal kwargs](../actions/actions.md#dynamic-and-literal-kwargs) |
| `default` | omitting the kwarg lowers as if the call supplied the literal |

A kwarg with none of the three is optional.

*(Spec: [LADP.8.5.1])*

### `default`

**`default -? literal`**

A `default` fits the kwarg's declared type; one that does not is refused with `DS_VALIDATE_SERVICE_KWARG_DEFAULT_TYPE`.

| Kwarg type | `default` |
|---|---|
| unit-typed | a quantity in the unit's dimension; where the dimension declares `storage int64`, a whole number of the kwarg's unit |
| dimension-typed | a quantity in that dimension |
| `Int`, `Float`, `String`, `Bool` | a literal of its type; a `Float` kwarg takes an `Int` literal too |
| `Bytes`, `Date`, `Duration`, `Interval`, `Json`, `Time` | none |
| a schema, `Schema`, an opaque type | none |

`-` is admitted only before a number or a unit literal. A negated unit literal's number is negated, then converted.

*(Spec: [LGRA.23.2])*

### Response declaration

**`response T`**, **`no response`**

Every service declares its response, as its last line.

| Condition | Code |
|---|---|
| no `response_decl` | `DS_VALIDATE_SERVICE_NO_RESPONSE_DECL` |
| `T` is not a schema | `DS_VALIDATE_SERVICE_RESPONSE_NOT_SCHEMA` |

`T` is a [response schema](call.md#response-schema). A `no response` service is at [`no response`](call.md#no-response).

*(Spec: [LGRA.23.2])*

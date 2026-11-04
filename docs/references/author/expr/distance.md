<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Distance

## Module access

Every function here is a member of the `distance` module, reached through [its import](../lang/imports.md#math-distance-and-calendar).

Operands are numeric: an `Int` promotes to `Float`. Any other operand type is a compile error. A wrong-typed `Json` leaf raises a [`TypeError`](../errors/fault-facts.md#typeerror-fact), and an unresolved path reads as `null`.

A count that is no declared arity is refused with `DS_VALIDATE_BAD_ARITY`.

*(Spec: [LEXP.5.1], [LEXP.5.8.1], [LEXP.7.17.1], [LEXP.10.2.4])*

## Geometric distances

Each returns a `Float`. Two dimensions take 4 operands, and three take 6.

*(Spec: [LEXP.5.3.1], [LEXP.5.9.1])*

### `euclidean`

**`distance.euclidean(x1, y1, x2, y2)`**, **`distance.euclidean(x1, y1, z1, x2, y2, z2)`**

The L₂ distance between two points.

```ds expression head
import distance
distance.euclidean(r.level, 0.0, 1.0, 2.0)
```

*(Spec: [LEXP.5.3.1])*

### `manhattan`

**`distance.manhattan(x1, y1, x2, y2)`**, **`distance.manhattan(x1, y1, z1, x2, y2, z2)`**

The L₁ distance between two points.

```ds expression head
import distance
distance.manhattan(r.level, 0.0, 1.0, 2.0)
```

*(Spec: [LEXP.5.3.1])*

### `chebyshev`

**`distance.chebyshev(x1, y1, x2, y2)`**, **`distance.chebyshev(x1, y1, z1, x2, y2, z2)`**

The L∞ distance between two points.

```ds expression head
import distance
distance.chebyshev(r.level, 0.0, 1.0, 2.0)
```

*(Spec: [LEXP.5.3.1])*

## Vector length

### `hypotenuse`

**`distance.hypotenuse(x, y)`**, **`distance.hypotenuse(x, y, z)`**

The length of a vector from the origin, a `Float`: √(x² + y²), or √(x² + y² + z²).

```ds expression head
import distance
distance.hypotenuse(r.level, 2.0)
```

*(Spec: [LEXP.5.5], [LEXP.5.8.1], [LEXP.5.9.1])*

## Cosine distance

### `cosine`

**`distance.cosine(ax, ay, bx, by)`**, **`distance.cosine(ax, ay, az, bx, by, bz)`**

The distance `1 - cos(θ)` between two vectors, a `Float` in [0, 2].

The result is `1 - (a·b) / (√(a·a) × √(b·b))`: each sum taken left to right over the components in argument order, the two norms taken separately and then multiplied, and every operation rounded once. When either vector is zero, the result is NaN.

```ds expression head
import distance
distance.cosine(r.level, 0.0, 1.0, 2.0)
```

*(Spec: [LEXP.5.7.1], [LEXP.5.7.3], [LEXP.5.9.1])*

## Great-circle distance

### `great_circle`

**`distance.great_circle(lat1, lon1, lat2, lon2)`**

The distance along the surface of a sphere between two points, as a `length` in `meter`.

The sphere's radius is the binary64 nearest 6 371 008.8 m. The arithmetic is the composition at [LEXP.5.11.2](inv:specs:std:label#lexp-5-11-2). The result differs from the geodesic distance on the WGS 84 ellipsoid by up to 0.6% of the distance.

Each argument is a `Float` in degrees, an `Int` converting to `Float`. An `angle` argument converts to `degree` by its unit. Latitude is in [−90, 90], positive north. Longitude is in [−180, 180], positive east.

A latitude or longitude outside its range, or any NaN or infinite argument, gives NaN without evaluating the composition. A `<`, `<=`, `>`, `>=` or `==` comparison with a NaN is false, so a rule that compares the result with a distance does not match it.

```ds expression head
import distance
distance.great_circle(r.level, 0.0, 1.0, 2.0)
```

*(Spec: [LEXP.5.11.1], [LEXP.5.11.2], [LEXP.5.11.3], [LEXP.5.9.1])*

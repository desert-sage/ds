-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| [LDET.3.2.8], fixed precision: the binary value correctly rounded to that
||| many decimal places, ties to even. This module proves that the primitives
||| of runtime/src/libds/float_fmt.c, taken at their contracts, compose into
||| exactly that rounding, for every m, every s and every precision.
|||
||| WHAT IS PROVED, unbounded (what CBMC cannot reach):
|||
|||   * The digits are the value's. A double's fraction is m = ip*2^s + F0
|||     (ds_fx_frac_init's contract) and each digit step is
|||     10 F = d * 2^s + F' with F' < 2^s (ds_fx_next_digit's). After K steps
|||     the kept integer Q (ip followed by the K digits) and the remainder F
|||     are the Euclidean quotient and remainder of m * 10^K by 2^s
|||     (`ldet_3_2_8__digits_exact`). Every digit is below 10
|||     (`ldet_3_2_8__digit_lt`).
|||   * The decision rounds. ds_fx_plan keeps Q, or takes Q + 1, by comparing F
|||     with half a step (ds_fx_cmp_half's contract) and, at a tie, by the
|||     parity of Q's last digit, which is Q's parity
|||     (`ldet_3_2_8__parity_last`). Whichever it takes is m * 10^K / 2^s
|||     correctly rounded, ties to even (`ldet_3_2_8__plan_rounds`), and that
|||     rounding is unique (`ldet_3_2_8__rounding_unique`).
|||   * Nothing rounds at s places or more. When K = s the remainder is 0
|||     (`ldet_3_2_8__exact_at_s`), so ds_fx_plan may skip the comparison
|||     there, and every place after s is 0.
|||   * The write pass is the rounded number. Adding one to digits ending in
|||     t nines writes t zeros after the incremented digit
|||     (`ldet_3_2_8__carry`), or carries into the integer part when every
|||     place is 9 (`ldet_3_2_8__carry_into_ip`), and the incremented digit
|||     is still a digit (`ldet_3_2_8__inc_digit`).
|||   * The integer path. One long-division pass of ds_fx_divmod_1e9 over the
|||     limbs, high to low, returns N mod 10^9 and leaves the quotient's limbs
|||     (`ldet_3_2_8__divmod_sound`), and every quotient limb fits a limb
|||     (`ldet_3_2_8__divmod_limb_fits`). Repeated as fx_put_big_int repeats
|||     it -- a pass, then a pass on the quotient while any limb is nonzero --
|||     the remainders pushed are N's base-10^9 chunks, least significant
|||     first (`ldet_3_2_8__chunks_value`), each below 10^9
|||     (`ldet_3_2_8__chunks_below`), the leading one nonzero when N is
|||     (`ldet_3_2_8__chunks_top`), and the one chunk 0 when N is 0
|||     (`ldet_3_2_8__chunks_of_zero`). fx_is_zero's limb test is the value
|||     test: zero limbs are the number 0 and a nonzero limb a positive number
|||     (`ldet_3_2_8__hv_zero`, `ldet_3_2_8__hv_nonzero`).
|||
||| THE SPECIFICATION is `ldet_3_2_8__rounds`: k is a nearest integer to
||| num / (h + h), and the even one at a tie. It is written as inequalities,
||| not as a formula for k, so that the formula the code uses is something
||| proved, not something assumed.
|||
||| WHAT THIS DOES NOT ESTABLISH, and where each part is:
|||
|||   * That the C meets the contracts. That is formal/cbmc/ldet_3_2_8__fixed.c:
|||     frac_init, next_digit and cmp_half exactly over every s to 1074,
|||     int_init over its whole domain, and bounds for the rest.
|||   * That ds_fx_plan's loop and pass 2 of ds_fmt_float_fixed have the shape
|||     the relations below give them -- K applications of next_digit, the
|||     carry stop at the last non-9 place, the C's `last & 1` read as Q's
|||     parity -- and that fx_put_big_int's do-while has `Ldet_3_2_8__Chunks`'s:
|||     a pass, its remainder pushed, again while fx_is_zero says no. Readings
|||     of a few lines of C; the first is checked by CBMC end to end on its
|||     domain (ldet_3_2_8__plan_rounds_p0, _p1).
|||   * That the do-while ends. A pass on a positive number returns a smaller
|||     quotient when the divisor is two or more, so it does; the module takes
|||     a finished run of passes as given and says what its chunks are.
|||   * That the uint64 arithmetic of ds_fx_divmod_1e9 equals Nat arithmetic.
|||     `ldet_3_2_8__divmod_limb_fits` gives the bound that makes it so
|||     (rem < 10^9, so rem * 2^32 + w < 10^9 * 2^32 < 2^64).
|||   * Concrete constants. Everything is over a symbolic base, half-step h
|||     (2^(s-1)) and divisor; the instances are 10, 2^(s-1), 2^32 and 10^9.
|||
||| %default total; no believe_me, assert_total, assert_smaller or postulate.
||| Standalone: it imports only the base library. So it restates four small
||| lemmas the lane has elsewhere, unexported or deep in a chain:
||| `ldet_3_2_8__lte_neq_lt` (Lcyc/Termination), and
||| `ldet_3_2_8__mult_lte_left`, `_mult_lte_right`, `_remainder_unique`
||| (CrU128Mul, whose names are private).
module FixedRound

import Data.Nat
import Data.Bool
import Data.List
import Data.List.Quantifiers

%default total
%unbound_implicits off

-- ── vocabulary ──────────────────────────────────────────────────────────────

||| b^k, by recursion on k.
--@spec [LDET.3.2.8]
ldet_3_2_8__pw : Nat -> Nat -> Nat
ldet_3_2_8__pw b Z = 1
ldet_3_2_8__pw b (S k) = b * ldet_3_2_8__pw b k

||| Parity: the tie-break's "even".
--@spec [LDET.3.2.8]
ldet_3_2_8__even : Nat -> Bool
ldet_3_2_8__even Z = True
ldet_3_2_8__even (S Z) = False
ldet_3_2_8__even (S (S n)) = ldet_3_2_8__even n

||| k is a nearest integer to num / (h + h): within half a step either way.
--@spec [LDET.3.2.8]
ldet_3_2_8__near : (num, h, k : Nat) -> Type
ldet_3_2_8__near num h k = (LTE (k * (h + h)) (num + h), LTE num (k * (h + h) + h))

||| At a tie -- num / (h + h) exactly half way -- k is even.
--@spec [LDET.3.2.8]
ldet_3_2_8__tie_even : (num, h, k : Nat) -> Type
ldet_3_2_8__tie_even num h k =
  Either (k * (h + h) = num + h) (num = k * (h + h) + h) -> ldet_3_2_8__even k = True

||| [LDET.3.2.8]'s rounding: k is num / (h + h) correctly rounded, ties to even.
--@spec [LDET.3.2.8]
ldet_3_2_8__rounds : (num, h, k : Nat) -> Type
ldet_3_2_8__rounds num h k = (ldet_3_2_8__near num h k, ldet_3_2_8__tie_even num h k)

||| The integer whose decimal digits are ip followed by ds, the newest digit
||| first: ip * b^(length ds) + the digits.
--@spec [LDET.3.2.8]
ldet_3_2_8__qv : (b, ip : Nat) -> List Nat -> Nat
ldet_3_2_8__qv b ip [] = ip
ldet_3_2_8__qv b ip (d :: ds) = b * ldet_3_2_8__qv b ip ds + d

||| ds_fx_next_digit's contract, applied once per kept place from F0: in base
||| b with step n, b F = d n + F' and F' < n. Digits newest first.
--@spec [LDET.3.2.8]
data Ldet_3_2_8__Trace : (b, n, f0 : Nat) -> List Nat -> Nat -> Type where
  TNil  : {b, n, f0 : Nat} -> Ldet_3_2_8__Trace b n f0 [] f0
  TCons : {b, n, f0, f, d, f' : Nat} -> {ds : List Nat}
       -> Ldet_3_2_8__Trace b n f0 ds f
       -> b * f = d * n + f' -> LT f' n
       -> Ldet_3_2_8__Trace b n f0 (d :: ds) f'

||| ds_fx_plan's decision, from ds_fx_cmp_half's three-way answer on the
||| remainder f against half a step h, and the parity of the kept integer q:
||| k is what it keeps, q or q + 1.
--@spec [LDET.3.2.8]
data Ldet_3_2_8__Decide : (f, h, q, k : Nat) -> Type where
  DBelow    : {f, h, q : Nat} -> LT f h -> Ldet_3_2_8__Decide f h q q
  DAbove    : {f, h, q : Nat} -> LT h f -> Ldet_3_2_8__Decide f h q (S q)
  DHalfEven : {f, h, q : Nat} -> f = h -> ldet_3_2_8__even q = True
           -> Ldet_3_2_8__Decide f h q q
  DHalfOdd  : {f, h, q : Nat} -> f = h -> ldet_3_2_8__even q = False
           -> Ldet_3_2_8__Decide f h q (S q)

-- ── arithmetic ──────────────────────────────────────────────────────────────

||| A number does not grow by adding a positive one to itself.
--@derives [LDET.3.2.8]
ldet_3_2_8__no_grow : (a, y : Nat) -> a = a + S y -> Void
ldet_3_2_8__no_grow a y eq =
  succNotLTEpred (replace {p = \z => LTE z (a + y)}
                    (trans eq (sym (plusSuccRightSucc a y))) (lteAddRight a))

||| Multiplication on the right keeps the order.
--@derives [LDET.3.2.8]
ldet_3_2_8__mult_lte_left : (a, b, c : Nat) -> LTE a b -> LTE (a * c) (b * c)
ldet_3_2_8__mult_lte_left Z b c LTEZero = LTEZero
ldet_3_2_8__mult_lte_left (S a) (S b) c (LTESucc le) =
  plusLteMonotoneLeft c (a * c) (b * c) (ldet_3_2_8__mult_lte_left a b c le)

||| Multiplication on the left keeps the order.
--@derives [LDET.3.2.8]
ldet_3_2_8__mult_lte_right : (c, a, b : Nat) -> LTE a b -> LTE (c * a) (c * b)
ldet_3_2_8__mult_lte_right c a b le =
  replace {p = \z => LTE z (c * b)} (multCommutative a c)
    (replace {p = \z => LTE (a * c) z} (multCommutative b c)
       (ldet_3_2_8__mult_lte_left a b c le))

||| Euclid's remainder is unique: two decompositions of one number with
||| remainders below the divisor have one remainder.
--@derives [LDET.3.2.8]
ldet_3_2_8__remainder_unique_cmp : (n, k, k2, res, res2 : Nat) -> CmpNat k k2
                                -> LT res n -> LT res2 n
                                -> k * n + res = k2 * n + res2 -> res = res2
ldet_3_2_8__remainder_unique_cmp n k _ res res2 CmpEQ hr hr2 eq =
  plusLeftCancel (k * n) res res2 eq
ldet_3_2_8__remainder_unique_cmp n k _ res res2 (CmpLT d) hr hr2 eq =
  absurd (succNotLTEpred (transitive hr ge))
  where
    e3 : res = (n + d * n) + res2
    e3 = plusLeftCancel (k * n) res ((n + d * n) + res2)
           (trans eq (trans (cong (+ res2) (multDistributesOverPlusLeft k (S d) n))
                            (sym (plusAssociative (k * n) (n + d * n) res2))))
    ge : LTE n res
    ge = replace {p = \z => LTE n z} (sym e3)
           (transitive (lteAddRight n) (lteAddRight (n + d * n)))
ldet_3_2_8__remainder_unique_cmp n _ k2 res res2 (CmpGT d) hr hr2 eq =
  absurd (succNotLTEpred (transitive hr2 ge))
  where
    e3 : (n + d * n) + res = res2
    e3 = plusLeftCancel (k2 * n) ((n + d * n) + res) res2
           (trans (plusAssociative (k2 * n) (n + d * n) res)
                  (trans (sym (cong (+ res) (multDistributesOverPlusLeft k2 (S d) n))) eq))
    ge : LTE n res2
    ge = replace {p = \z => LTE n z} e3
           (transitive (lteAddRight n) (lteAddRight (n + d * n)))

--@derives [LDET.3.2.8]
ldet_3_2_8__remainder_unique : (n, k, k2, res, res2 : Nat) -> LT res n -> LT res2 n
                            -> k * n + res = k2 * n + res2 -> res = res2
ldet_3_2_8__remainder_unique n k k2 res res2 hr hr2 eq =
  ldet_3_2_8__remainder_unique_cmp n k k2 res res2 (cmp k k2) hr hr2 eq

||| x * n below y * n puts x below y.
--@derives [LDET.3.2.8]
ldet_3_2_8__lt_of_mult_lt : (x, y, n : Nat) -> LT (x * n) (y * n) -> LT x y
ldet_3_2_8__lt_of_mult_lt x y n lt with (isLT x y)
  _ | Yes yes = yes
  _ | No no =
    absurd (succNotLTEpred (transitive lt (ldet_3_2_8__mult_lte_left y x n (notLTImpliesGTE no))))

||| At most, and not equal, is below.
--@derives [LDET.3.2.8]
ldet_3_2_8__lte_neq_lt : (d, k : Nat) -> LTE d k -> Not (d = k) -> LT d k
ldet_3_2_8__lte_neq_lt Z Z _ ne = absurd (ne Refl)
ldet_3_2_8__lte_neq_lt Z (S k) _ _ = LTESucc LTEZero
ldet_3_2_8__lte_neq_lt (S d) Z le _ = absurd le
ldet_3_2_8__lte_neq_lt (S d) (S k) (LTESucc le) ne =
  LTESucc (ldet_3_2_8__lte_neq_lt d k le (\e => ne (cong S e)))

||| Moving one factor past another: a * (x * y) = x * (a * y).
--@derives [LDET.3.2.8]
ldet_3_2_8__mult_swap : (a, x, y : Nat) -> a * (x * y) = x * (a * y)
ldet_3_2_8__mult_swap a x y =
  trans (multAssociative a x y)
  (trans (cong (* y) (multCommutative a x))
         (sym (multAssociative x a y)))

||| (a c)^k = a^k c^k.
--@derives [LDET.3.2.8]
ldet_3_2_8__pw_mul : (a, c, k : Nat)
                  -> ldet_3_2_8__pw (a * c) k = ldet_3_2_8__pw a k * ldet_3_2_8__pw c k
ldet_3_2_8__pw_mul a c Z = Refl
ldet_3_2_8__pw_mul a c (S k) =
  trans (cong ((a * c) *) (ldet_3_2_8__pw_mul a c k)) regroup
  where
    regroup : (a * c) * (ldet_3_2_8__pw a k * ldet_3_2_8__pw c k)
            = (a * ldet_3_2_8__pw a k) * (c * ldet_3_2_8__pw c k)
    regroup =
      trans (sym (multAssociative a c (ldet_3_2_8__pw a k * ldet_3_2_8__pw c k)))
      (trans (cong (a *) (ldet_3_2_8__mult_swap c (ldet_3_2_8__pw a k) (ldet_3_2_8__pw c k)))
             (multAssociative a (ldet_3_2_8__pw a k) (c * ldet_3_2_8__pw c k)))

||| A power of a positive base is positive.
--@derives [LDET.3.2.8]
ldet_3_2_8__pw_pos : (b, k : Nat) -> LTE 1 b -> LTE 1 (ldet_3_2_8__pw b k)
ldet_3_2_8__pw_pos b Z _ = LTESucc LTEZero
ldet_3_2_8__pw_pos b (S k) hb =
  transitive (ldet_3_2_8__pw_pos b k hb)
    (replace {p = \z => LTE z (b * ldet_3_2_8__pw b k)}
       (plusZeroRightNeutral (ldet_3_2_8__pw b k))
       (ldet_3_2_8__mult_lte_left 1 b (ldet_3_2_8__pw b k) hb))

-- ── parity ──────────────────────────────────────────────────────────────────

||| The next number has the other parity.
--@derives [LDET.3.2.8]
ldet_3_2_8__even_succ : (n : Nat) -> ldet_3_2_8__even (S n) = not (ldet_3_2_8__even n)
ldet_3_2_8__even_succ Z = Refl
ldet_3_2_8__even_succ (S n) =
  trans (sym (notInvolutive (ldet_3_2_8__even n)))
        (cong not (sym (ldet_3_2_8__even_succ n)))

||| Adding a number to itself does not change parity.
--@derives [LDET.3.2.8]
ldet_3_2_8__even_double : (x, d : Nat)
                       -> ldet_3_2_8__even ((x + x) + d) = ldet_3_2_8__even d
ldet_3_2_8__even_double Z d = Refl
ldet_3_2_8__even_double (S x) d =
  rewrite sym (plusSuccRightSucc x x) in ldet_3_2_8__even_double x d

||| In an even base, a number has its last digit's parity: so ds_fx_plan's
||| `last & 1` is the kept integer's parity (base 10 = 5 + 5).
--@derives [LDET.3.2.8]
ldet_3_2_8__parity_last : (c, q, d : Nat)
                       -> ldet_3_2_8__even ((c + c) * q + d) = ldet_3_2_8__even d
ldet_3_2_8__parity_last c q d =
  rewrite multDistributesOverPlusLeft c c q in ldet_3_2_8__even_double (c * q) d

-- ── the rounding, case by case ──────────────────────────────────────────────

||| The remainder below half a step: q is the rounding.
--@derives [LDET.3.2.8]
ldet_3_2_8__rounds_below : (num, h, q, r : Nat) -> num = q * (h + h) + r -> LT r h
                        -> ldet_3_2_8__rounds num h q
ldet_3_2_8__rounds_below num h q r e lt = ((lo, hi), tie)
  where
    c1 : num + h = q * (h + h) + (r + h)
    c1 = trans (cong (+ h) e) (sym (plusAssociative (q * (h + h)) r h))
    lo : LTE (q * (h + h)) (num + h)
    lo = replace {p = \z => LTE (q * (h + h)) z} (sym c1) (lteAddRight (q * (h + h)))
    hi : LTE num (q * (h + h) + h)
    hi = replace {p = \z => LTE z (q * (h + h) + h)} (sym e)
           (plusLteMonotoneLeft (q * (h + h)) r h (lteSuccLeft lt))
    hr : LTE h (r + h)
    hr = replace {p = \w => LTE h w} (plusCommutative h r) (lteAddRight h)
    tieL : q * (h + h) = num + h -> Void
    tieL eq =
      succNotLTEzero (replace {p = \w => LTE (S r) w}
                        (sym (plusLeftCancel (q * (h + h)) 0 (r + h)
                                (trans (plusZeroRightNeutral (q * (h + h))) (trans eq c1))))
                        (transitive lt hr))
    tieR : num = q * (h + h) + h -> Void
    tieR eq =
      succNotLTEpred (replace {p = \w => LTE (S w) h}
                        (plusLeftCancel (q * (h + h)) r h (trans (sym e) eq)) lt)
    tie : Either (q * (h + h) = num + h) (num = q * (h + h) + h) -> ldet_3_2_8__even q = True
    tie (Left eq) = absurd (tieL eq)
    tie (Right eq) = absurd (tieR eq)

||| The remainder above half a step: q + 1 is the rounding.
--@derives [LDET.3.2.8]
ldet_3_2_8__rounds_above : (num, h, q, r : Nat) -> num = q * (h + h) + r -> LT h r
                        -> LT r (h + h) -> ldet_3_2_8__rounds num h (S q)
ldet_3_2_8__rounds_above num h q r e lt1 lt2 = ((lo, hi), tie)
  where
    eqL : (h + h) + q * (h + h) = (q * (h + h) + h) + h
    eqL = trans (plusCommutative (h + h) (q * (h + h))) (plusAssociative (q * (h + h)) h h)
    lo : LTE ((h + h) + q * (h + h)) (num + h)
    lo = replace {p = \z => LTE z (num + h)} (sym eqL)
           (replace {p = \z => LTE ((q * (h + h) + h) + h) z} (cong (+ h) (sym e))
              (plusLteMonotoneRight h (q * (h + h) + h) (q * (h + h) + r)
                 (plusLteMonotoneLeft (q * (h + h)) h r (lteSuccLeft lt1))))
    hi : LTE num (((h + h) + q * (h + h)) + h)
    hi = replace {p = \z => LTE z (((h + h) + q * (h + h)) + h)} (sym e)
           (transitive (plusLteMonotoneLeft (q * (h + h)) r (h + h) (lteSuccLeft lt2))
              (replace {p = \z => LTE (q * (h + h) + (h + h)) (z + h)}
                 (plusCommutative (q * (h + h)) (h + h))
                 (lteAddRight (q * (h + h) + (h + h)))))
    eqR : ((h + h) + q * (h + h)) + h = q * (h + h) + ((h + h) + h)
    eqR = trans (cong (+ h) (plusCommutative (h + h) (q * (h + h))))
                (sym (plusAssociative (q * (h + h)) (h + h) h))
    tieL : (h + h) + q * (h + h) = num + h -> Void
    tieL eq =
      succNotLTEpred (replace {p = \w => LTE (S w) r}
                        (plusLeftCancel (q * (h + h)) h r
                           (plusRightCancel (q * (h + h) + h) (q * (h + h) + r) h
                              (trans (sym eqL) (trans eq (cong (+ h) e)))))
                        lt1)
    tieR : num = ((h + h) + q * (h + h)) + h -> Void
    tieR eq =
      succNotLTEpred (transitive (LTESucc (lteAddRight (h + h)))
                        (replace {p = \w => LTE (S w) (h + h)}
                           (plusLeftCancel (q * (h + h)) r ((h + h) + h) (trans (sym e) (trans eq eqR)))
                           lt2))
    tie : Either ((h + h) + q * (h + h) = num + h) (num = ((h + h) + q * (h + h)) + h)
       -> ldet_3_2_8__even (S q) = True
    tie (Left eq) = absurd (tieL eq)
    tie (Right eq) = absurd (tieR eq)

||| Exactly half a step, q even: q is the rounding.
--@derives [LDET.3.2.8]
ldet_3_2_8__rounds_half_even : (num, h, q : Nat) -> num = q * (h + h) + h
                            -> ldet_3_2_8__even q = True -> ldet_3_2_8__rounds num h q
ldet_3_2_8__rounds_half_even num h q e ev = ((lo, hi), \_ => ev)
  where
    c : num + h = q * (h + h) + (h + h)
    c = trans (cong (+ h) e) (sym (plusAssociative (q * (h + h)) h h))
    lo : LTE (q * (h + h)) (num + h)
    lo = replace {p = \z => LTE (q * (h + h)) z} (sym c) (lteAddRight (q * (h + h)))
    hi : LTE num (q * (h + h) + h)
    hi = replace {p = \z => LTE z (q * (h + h) + h)} (sym e) reflexive

||| Exactly half a step, q odd: q + 1 is the rounding.
--@derives [LDET.3.2.8]
ldet_3_2_8__rounds_half_odd : (num, h, q : Nat) -> num = q * (h + h) + h
                           -> ldet_3_2_8__even q = False -> ldet_3_2_8__rounds num h (S q)
ldet_3_2_8__rounds_half_odd num h q e od = ((lo, hi), \_ => ev)
  where
    eqA : (h + h) + q * (h + h) = num + h
    eqA = trans (trans (plusCommutative (h + h) (q * (h + h))) (plusAssociative (q * (h + h)) h h))
                (cong (+ h) (sym e))
    lo : LTE ((h + h) + q * (h + h)) (num + h)
    lo = replace {p = \z => LTE ((h + h) + q * (h + h)) z} eqA reflexive
    hi : LTE num (((h + h) + q * (h + h)) + h)
    hi = replace {p = \z => LTE z (((h + h) + q * (h + h)) + h)} (sym e)
           (transitive
              (replace {p = \z => LTE (q * (h + h) + h) z} (plusCommutative (q * (h + h)) (h + h))
                 (plusLteMonotoneLeft (q * (h + h)) h (h + h) (lteAddRight h)))
              (lteAddRight ((h + h) + q * (h + h))))
    ev : ldet_3_2_8__even (S q) = True
    ev = trans (ldet_3_2_8__even_succ q) (cong not od)

-- ── the digits ──────────────────────────────────────────────────────────────

||| The trace keeps the remainder below a step.
--@derives [LDET.3.2.8]
ldet_3_2_8__trace_below : (b, n, f0, f : Nat) -> (ds : List Nat) -> LT f0 n
                       -> Ldet_3_2_8__Trace b n f0 ds f -> LT f n
ldet_3_2_8__trace_below b n f0 _ [] h0 TNil = h0
ldet_3_2_8__trace_below b n f0 _ (d :: ds) _ (TCons _ _ lt) = lt

||| THE DIGITS ARE THE VALUE'S. After K steps from m = ip n + F0, the kept
||| integer and the remainder are m b^K's quotient and remainder by n.
--@derives [LDET.3.2.8]
ldet_3_2_8__digits_exact : (b, n, m, ip, f0, f : Nat) -> (ds : List Nat)
                        -> m = ip * n + f0 -> Ldet_3_2_8__Trace b n f0 ds f
                        -> m * ldet_3_2_8__pw b (length ds) = ldet_3_2_8__qv b ip ds * n + f
ldet_3_2_8__digits_exact b n m ip f0 _ [] e0 TNil = trans (multOneRightNeutral m) e0
ldet_3_2_8__digits_exact b n m ip f0 f' (d :: ds) e0 (TCons {f} tr e lt) =
  trans s1 (trans s2 (trans s3 (trans s4 (trans s5 s6))))
  where
    p : Nat
    p = ldet_3_2_8__pw b (length ds)
    q : Nat
    q = ldet_3_2_8__qv b ip ds
    ih : m * p = q * n + f
    ih = ldet_3_2_8__digits_exact b n m ip f0 f ds e0 tr
    s1 : m * (b * p) = b * (m * p)
    s1 = ldet_3_2_8__mult_swap m b p
    s2 : b * (m * p) = b * (q * n + f)
    s2 = cong (b *) ih
    s3 : b * (q * n + f) = b * (q * n) + b * f
    s3 = multDistributesOverPlusRight b (q * n) f
    s4 : b * (q * n) + b * f = (b * q) * n + (d * n + f')
    s4 = cong2 (+) (multAssociative b q n) e
    s5 : (b * q) * n + (d * n + f') = ((b * q) * n + d * n) + f'
    s5 = plusAssociative ((b * q) * n) (d * n) f'
    s6 : ((b * q) * n + d * n) + f' = (b * q + d) * n + f'
    s6 = cong (+ f') (sym (multDistributesOverPlusLeft (b * q) d n))

||| Every digit is below the base: the remainder is below a step.
--@derives [LDET.3.2.8]
ldet_3_2_8__digit_lt : (k, n, f, d, f' : Nat) -> LT f n -> S k * f = d * n + f'
                    -> LT d (S k)
ldet_3_2_8__digit_lt k n f d f' hf e =
  ldet_3_2_8__lt_of_mult_lt d (S k) n (transitive (LTESucc dle) bf)
  where
    dle : LTE (d * n) (S k * f)
    dle = replace {p = \z => LTE (d * n) z} (sym e) (lteAddRight (d * n))
    step : LTE (S (S k * f)) (S k * S f)
    step = replace {p = \z => LTE (S (S k * f)) z} (sym (multRightSuccPlus (S k) f))
             (LTESucc (replace {p = \z => LTE (S k * f) z} (plusCommutative (S k * f) k)
                         (lteAddRight (S k * f))))
    bf : LTE (S (S k * f)) (S k * n)
    bf = transitive step (ldet_3_2_8__mult_lte_right (S k) (S f) n hf)

-- ── the plan rounds ─────────────────────────────────────────────────────────

||| THE THEOREM. With x = m / 2^s, h = 2^(s-1) (so h + h = 2^s), the fraction
||| started from m = ip 2^s + F0, K digits taken by next_digit's contract and
||| the decision taken by cmp_half's and the parity: what the plan keeps is
||| x 10^K correctly rounded, ties to even.
--@derives [LDET.3.2.8]
ldet_3_2_8__plan_rounds : (m, h, ip, f0, f, k : Nat) -> (ds : List Nat)
                       -> m = ip * (h + h) + f0 -> LT f0 (h + h)
                       -> Ldet_3_2_8__Trace 10 (h + h) f0 ds f
                       -> Ldet_3_2_8__Decide f h (ldet_3_2_8__qv 10 ip ds) k
                       -> ldet_3_2_8__rounds (m * ldet_3_2_8__pw 10 (length ds)) h k
ldet_3_2_8__plan_rounds m h ip f0 f _ ds e0 h0 tr (DBelow lt) =
  ldet_3_2_8__rounds_below _ h _ f (ldet_3_2_8__digits_exact 10 (h + h) m ip f0 f ds e0 tr) lt
ldet_3_2_8__plan_rounds m h ip f0 f _ ds e0 h0 tr (DAbove lt) =
  ldet_3_2_8__rounds_above _ h _ f (ldet_3_2_8__digits_exact 10 (h + h) m ip f0 f ds e0 tr) lt
    (ldet_3_2_8__trace_below 10 (h + h) f0 f ds h0 tr)
ldet_3_2_8__plan_rounds m h ip f0 f _ ds e0 h0 tr (DHalfEven fh ev) =
  ldet_3_2_8__rounds_half_even _ h _
    (replace {p = \z => m * ldet_3_2_8__pw 10 (length ds) = ldet_3_2_8__qv 10 ip ds * (h + h) + z}
       fh (ldet_3_2_8__digits_exact 10 (h + h) m ip f0 f ds e0 tr)) ev
ldet_3_2_8__plan_rounds m h ip f0 f _ ds e0 h0 tr (DHalfOdd fh od) =
  ldet_3_2_8__rounds_half_odd _ h _
    (replace {p = \z => m * ldet_3_2_8__pw 10 (length ds) = ldet_3_2_8__qv 10 ip ds * (h + h) + z}
       fh (ldet_3_2_8__digits_exact 10 (h + h) m ip f0 f ds e0 tr)) od


-- ── nothing rounds at s places or more ──────────────────────────────────────

||| NOTHING ROUNDS AT s PLACES. With s = S s' and h = 2^s' (so h + h = 2^s):
||| after s digits the remainder is 0, because m 10^s = (m 5^s) 2^s exactly.
--@derives [LDET.3.2.8]
ldet_3_2_8__exact_at_s : (s', m, ip, f0, f : Nat) -> (ds : List Nat)
                      -> length ds = S s'
                      -> m = ip * (ldet_3_2_8__pw 2 s' + ldet_3_2_8__pw 2 s') + f0
                      -> LT f0 (ldet_3_2_8__pw 2 s' + ldet_3_2_8__pw 2 s')
                      -> Ldet_3_2_8__Trace 10 (ldet_3_2_8__pw 2 s' + ldet_3_2_8__pw 2 s') f0 ds f
                      -> f = 0
ldet_3_2_8__exact_at_s s' m ip f0 f ds len e0 h0 tr =
  ldet_3_2_8__remainder_unique hh q (m * ldet_3_2_8__pw 5 (S s')) f 0 hf pos (trans (sym ex) whole)
  where
    h : Nat
    h = ldet_3_2_8__pw 2 s'
    hh : Nat
    hh = h + h
    q : Nat
    q = ldet_3_2_8__qv 10 ip ds
    ex : m * ldet_3_2_8__pw 10 (length ds) = q * hh + f
    ex = ldet_3_2_8__digits_exact 10 hh m ip f0 f ds e0 tr
    two : ldet_3_2_8__pw 2 (S s') = hh
    two = cong (h +) (plusZeroRightNeutral h)
    whole : m * ldet_3_2_8__pw 10 (length ds) = (m * ldet_3_2_8__pw 5 (S s')) * hh + 0
    whole =
      trans (cong (\z => m * ldet_3_2_8__pw 10 z) len)
      (trans (cong (m *) (ldet_3_2_8__pw_mul 5 2 (S s')))
      (trans (multAssociative m (ldet_3_2_8__pw 5 (S s')) (ldet_3_2_8__pw 2 (S s')))
      (trans (cong ((m * ldet_3_2_8__pw 5 (S s')) *) two)
             (sym (plusZeroRightNeutral ((m * ldet_3_2_8__pw 5 (S s')) * hh))))))
    hf : LT f hh
    hf = ldet_3_2_8__trace_below 10 hh f0 f ds h0 tr
    pos : LT 0 hh
    pos = transitive (ldet_3_2_8__pw_pos 2 s' (LTESucc LTEZero)) (lteAddRight h)

-- ── the write pass ──────────────────────────────────────────────────────────

||| t zeros after the kept digits multiply the number by b^t: so the places
||| past s, which the write pass fills with 0, are the value's.
--@derives [LDET.3.2.8]
ldet_3_2_8__zeros_val : (b, ip, t : Nat) -> (ys : List Nat)
                     -> ldet_3_2_8__qv b ip (replicate t 0 ++ ys)
                      = ldet_3_2_8__qv b ip ys * ldet_3_2_8__pw b t
ldet_3_2_8__zeros_val b ip Z ys = sym (multOneRightNeutral (ldet_3_2_8__qv b ip ys))
ldet_3_2_8__zeros_val b ip (S t) ys =
  trans (plusZeroRightNeutral (b * ldet_3_2_8__qv b ip (replicate t 0 ++ ys)))
  (trans (cong (b *) (ldet_3_2_8__zeros_val b ip t ys))
         (ldet_3_2_8__mult_swap b (ldet_3_2_8__qv b ip ys) (ldet_3_2_8__pw b t)))

||| t nines (the base's largest digit, k, in base S k) and one more: the next
||| number up is the digits before them plus one, times b^t.
--@derives [LDET.3.2.8]
ldet_3_2_8__nines_val : (k, ip, t : Nat) -> (ys : List Nat)
                     -> S (ldet_3_2_8__qv (S k) ip (replicate t k ++ ys))
                      = S (ldet_3_2_8__qv (S k) ip ys) * ldet_3_2_8__pw (S k) t
ldet_3_2_8__nines_val k ip Z ys = sym (multOneRightNeutral (S (ldet_3_2_8__qv (S k) ip ys)))
ldet_3_2_8__nines_val k ip (S t) ys =
  trans (plusSuccRightSucc (S k * q') k)
  (trans (plusCommutative (S k * q') (S k))
  (trans (sym (multRightSuccPlus (S k) q'))
  (trans (cong (S k *) (ldet_3_2_8__nines_val k ip t ys))
         (ldet_3_2_8__mult_swap (S k) (S (ldet_3_2_8__qv (S k) ip ys)) (ldet_3_2_8__pw (S k) t)))))
  where
    q' : Nat
    q' = ldet_3_2_8__qv (S k) ip (replicate t k ++ ys)

||| THE CARRY. Rounding up digits that end in t nines after a digit d: the
||| write pass's d + 1 followed by t zeros is that number plus one.
--@derives [LDET.3.2.8]
ldet_3_2_8__carry : (k, ip, t, d : Nat) -> (ys : List Nat)
                 -> ldet_3_2_8__qv (S k) ip (replicate t 0 ++ (S d :: ys))
                  = S (ldet_3_2_8__qv (S k) ip (replicate t k ++ (d :: ys)))
ldet_3_2_8__carry k ip t d ys =
  trans (ldet_3_2_8__zeros_val (S k) ip t (S d :: ys))
  (trans (cong (* ldet_3_2_8__pw (S k) t)
               (sym (plusSuccRightSucc (S k * ldet_3_2_8__qv (S k) ip ys) d)))
         (sym (ldet_3_2_8__nines_val k ip t (d :: ys))))

||| THE CARRY INTO THE INTEGER PART. Every kept place 9: the write pass's
||| ip + 1 followed by zeros is that number plus one.
--@derives [LDET.3.2.8]
ldet_3_2_8__carry_into_ip : (k, ip, t : Nat)
                         -> ldet_3_2_8__qv (S k) (S ip) (replicate t 0 ++ [])
                          = S (ldet_3_2_8__qv (S k) ip (replicate t k ++ []))
ldet_3_2_8__carry_into_ip k ip t =
  trans (ldet_3_2_8__zeros_val (S k) (S ip) t [])
        (sym (ldet_3_2_8__nines_val k ip t []))

||| The digit the carry stops at is a digit below the largest, so adding one
||| to it leaves a digit.
--@derives [LDET.3.2.8]
ldet_3_2_8__inc_digit : (k, d : Nat) -> LT d (S k) -> Not (d = k) -> LT (S d) (S k)
ldet_3_2_8__inc_digit k d lt ne = LTESucc (ldet_3_2_8__lte_neq_lt d k (fromLteSucc lt) ne)

-- ── the integer path ────────────────────────────────────────────────────────

||| A number from its limbs, most significant first, in base `base`.
--@spec [LDET.3.2.8]
ldet_3_2_8__hv : (base, acc : Nat) -> List Nat -> Nat
ldet_3_2_8__hv base acc [] = acc
ldet_3_2_8__hv base acc (w :: ws) = ldet_3_2_8__hv base (acc * base + w) ws

||| One pass of ds_fx_divmod_1e9: each limb, high to low, with the running
||| remainder in front, divided by `dv` (10^9) -- the quotient limb and the
||| remainder by their defining equation.
--@spec [LDET.3.2.8]
data Ldet_3_2_8__DivTrace : (base, dv, rem : Nat) -> List Nat -> List Nat -> Nat -> Type where
  DNil  : {base, dv, rem : Nat} -> Ldet_3_2_8__DivTrace base dv rem [] [] rem
  DCons : {base, dv, rem, w, q, rem1, remF : Nat} -> {ws, qs : List Nat}
       -> rem * base + w = q * dv + rem1 -> LT rem1 dv
       -> Ldet_3_2_8__DivTrace base dv rem1 ws qs remF
       -> Ldet_3_2_8__DivTrace base dv rem (w :: ws) (q :: qs) remF

||| One pass divides: whatever was in front, the limbs equal the quotient limbs
||| times dv plus what is returned. From qacc = rem = 0: N = N' 10^9 + r.
--@derives [LDET.3.2.8]
ldet_3_2_8__divmod_sound : (base, dv, qacc, rem, remF : Nat) -> (ws, qs : List Nat)
                        -> Ldet_3_2_8__DivTrace base dv rem ws qs remF
                        -> ldet_3_2_8__hv base (qacc * dv + rem) ws
                         = ldet_3_2_8__hv base qacc qs * dv + remF
ldet_3_2_8__divmod_sound base dv qacc rem _ [] [] DNil = Refl
ldet_3_2_8__divmod_sound base dv qacc rem remF (w :: ws) (q :: qs) (DCons {rem1} e lt tr) =
  trans (cong (\z => ldet_3_2_8__hv base z ws) step)
        (ldet_3_2_8__divmod_sound base dv (qacc * base + q) rem1 remF ws qs tr)
  where
    swap : (qacc * dv) * base = (qacc * base) * dv
    swap = trans (sym (multAssociative qacc dv base))
           (trans (cong (qacc *) (multCommutative dv base))
                  (multAssociative qacc base dv))
    step : (qacc * dv + rem) * base + w = (qacc * base + q) * dv + rem1
    step =
      trans (cong (+ w) (multDistributesOverPlusLeft (qacc * dv) rem base))
      (trans (sym (plusAssociative ((qacc * dv) * base) (rem * base) w))
      (trans (cong2 (+) swap e)
      (trans (plusAssociative ((qacc * base) * dv) (q * dv) rem1)
             (cong (+ rem1) (sym (multDistributesOverPlusLeft (qacc * base) q dv))))))

||| Every quotient limb fits a limb: with rem below dv and w below the base,
||| rem base + w < dv base, so q < base. This is also what keeps the C's
||| uint64 `(rem << 32) | w` from wrapping, given 10^9 2^32 < 2^64.
--@derives [LDET.3.2.8]
ldet_3_2_8__divmod_limb_fits : (base, dv, rem, w, q, rem1 : Nat) -> LT rem dv -> LT w base
                            -> rem * base + w = q * dv + rem1 -> LT q base
ldet_3_2_8__divmod_limb_fits base dv rem w q rem1 hr hw e =
  ldet_3_2_8__lt_of_mult_lt q base dv
    (replace {p = \z => LT (q * dv) z} (multCommutative dv base) (transitive (LTESucc qle) cur))
  where
    qle : LTE (q * dv) (rem * base + w)
    qle = replace {p = \z => LTE (q * dv) z} (sym e) (lteAddRight (q * dv))
    cur : LTE (S (rem * base + w)) (dv * base)
    cur = transitive
            (replace {p = \z => LTE z (rem * base + base)} (sym (plusSuccRightSucc (rem * base) w))
               (plusLteMonotoneLeft (rem * base) (S w) base hw))
            (replace {p = \z => LTE z (dv * base)} (plusCommutative base (rem * base))
               (ldet_3_2_8__mult_lte_left (S rem) dv base hr))

-- ── the chunks ──────────────────────────────────────────────────────────────

||| fx_put_big_int's loop, as float_fmt.c has it: one pass of ds_fx_divmod_1e9
||| over the limbs from remainder 0, its remainder pushed as the next chunk,
||| and the same on the quotient limbs while any of them is nonzero
||| (fx_is_zero). A do-while, so there is always a first chunk. Chunks least
||| significant first, as the C stores them.
--@spec [LDET.3.2.8]
data Ldet_3_2_8__Chunks : (base, dv : Nat) -> List Nat -> List Nat -> Type where
  CLast : {base, dv, r : Nat} -> {ws, qs : List Nat}
       -> Ldet_3_2_8__DivTrace base dv 0 ws qs r -> All (\w => w = 0) qs
       -> Ldet_3_2_8__Chunks base dv ws [r]
  CMore : {base, dv, r : Nat} -> {ws, qs, rs : List Nat}
       -> Ldet_3_2_8__DivTrace base dv 0 ws qs r -> Not (All (\w => w = 0) qs)
       -> Ldet_3_2_8__Chunks base dv qs rs
       -> Ldet_3_2_8__Chunks base dv ws (r :: rs)

||| The most significant chunk, the last pushed, is nonzero.
--@spec [LDET.3.2.8]
data Ldet_3_2_8__TopNonzero : List Nat -> Type where
  TOne  : {r : Nat} -> LT 0 r -> Ldet_3_2_8__TopNonzero [r]
  TMore : {r : Nat} -> {rs : List Nat} -> Ldet_3_2_8__TopNonzero rs
       -> Ldet_3_2_8__TopNonzero (r :: rs)

||| Limbs all zero are the number 0.
--@derives [LDET.3.2.8]
ldet_3_2_8__hv_zero : (base : Nat) -> (ws : List Nat) -> All (\w => w = 0) ws
                   -> ldet_3_2_8__hv base 0 ws = 0
ldet_3_2_8__hv_zero base [] [] = Refl
ldet_3_2_8__hv_zero base (w :: ws) (e :: zs) = rewrite e in ldet_3_2_8__hv_zero base ws zs

||| Reading limbs never loses what was in front of them, in a base of one or
||| more.
--@derives [LDET.3.2.8]
ldet_3_2_8__hv_acc_lte : (base, acc : Nat) -> (ws : List Nat) -> LTE 1 base
                      -> LTE acc (ldet_3_2_8__hv base acc ws)
ldet_3_2_8__hv_acc_lte base acc [] h1 = reflexive
ldet_3_2_8__hv_acc_lte base acc (w :: ws) h1 =
  transitive step (ldet_3_2_8__hv_acc_lte base (acc * base + w) ws h1)
  where
    step : LTE acc (acc * base + w)
    step = transitive
             (replace {p = \z => LTE z (acc * base)} (multOneRightNeutral acc)
                (ldet_3_2_8__mult_lte_right acc 1 base h1))
             (lteAddRight (acc * base))

||| A nonzero limb is a positive number: with the one before, fx_is_zero's
||| limb test is the value test.
--@derives [LDET.3.2.8]
ldet_3_2_8__hv_nonzero : (base : Nat) -> (ws : List Nat) -> LTE 1 base
                      -> Not (All (\w => w = 0) ws) -> LT 0 (ldet_3_2_8__hv base 0 ws)
ldet_3_2_8__hv_nonzero base [] h1 nz = absurd (nz [])
ldet_3_2_8__hv_nonzero base (Z :: ws) h1 nz =
  ldet_3_2_8__hv_nonzero base ws h1 (\zs => nz (Refl :: zs))
ldet_3_2_8__hv_nonzero base (S w :: ws) h1 nz =
  transitive (LTESucc LTEZero) (ldet_3_2_8__hv_acc_lte base (S w) ws h1)

||| A pass from a remainder below the divisor returns one below it.
--@derives [LDET.3.2.8]
ldet_3_2_8__divtrace_below : (base, dv, rem, remF : Nat) -> (ws, qs : List Nat) -> LT rem dv
                          -> Ldet_3_2_8__DivTrace base dv rem ws qs remF -> LT remF dv
ldet_3_2_8__divtrace_below base dv rem _ [] [] hr DNil = hr
ldet_3_2_8__divtrace_below base dv rem remF (w :: ws) (q :: qs) hr (DCons {rem1} e lt tr) =
  ldet_3_2_8__divtrace_below base dv rem1 remF ws qs lt tr

||| THE CHUNKS ARE THE NUMBER. However many passes the loop ran, the chunks it
||| pushed, least significant first, are the limbs' number in base dv.
--@derives [LDET.3.2.8]
ldet_3_2_8__chunks_value : (base, dv : Nat) -> (ws, rs : List Nat)
                        -> Ldet_3_2_8__Chunks base dv ws rs
                        -> ldet_3_2_8__hv base 0 ws = ldet_3_2_8__qv dv 0 rs
ldet_3_2_8__chunks_value base dv ws _ (CLast {qs} {r} tr zs) =
  trans (ldet_3_2_8__divmod_sound base dv 0 0 r ws qs tr)
  (trans (cong (\z => z * dv + r) (ldet_3_2_8__hv_zero base qs zs))
         (sym (cong (+ r) (multCommutative dv 0))))
ldet_3_2_8__chunks_value base dv ws _ (CMore {qs} {r} {rs} tr nz ch) =
  trans (ldet_3_2_8__divmod_sound base dv 0 0 r ws qs tr)
  (trans (cong (\z => z * dv + r) (ldet_3_2_8__chunks_value base dv qs rs ch))
         (cong (+ r) (multCommutative (ldet_3_2_8__qv dv 0 rs) dv)))

||| EVERY CHUNK IS BELOW dv: each is a pass's remainder.
--@derives [LDET.3.2.8]
ldet_3_2_8__chunks_below : (base, dv : Nat) -> (ws, rs : List Nat) -> LT 0 dv
                        -> Ldet_3_2_8__Chunks base dv ws rs -> All (\c => LT c dv) rs
ldet_3_2_8__chunks_below base dv ws _ hd (CLast {qs} {r} tr zs) =
  [ldet_3_2_8__divtrace_below base dv 0 r ws qs hd tr]
ldet_3_2_8__chunks_below base dv ws _ hd (CMore {qs} {r} {rs} tr nz ch) =
  ldet_3_2_8__divtrace_below base dv 0 r ws qs hd tr
    :: ldet_3_2_8__chunks_below base dv qs rs hd ch

||| THE LEADING CHUNK IS NONZERO when the number is. The loop went on only
||| while a quotient limb was nonzero, and the pass it stopped after returned
||| that whole quotient, below dv, as the last chunk.
--@derives [LDET.3.2.8]
ldet_3_2_8__chunks_top : (base, dv : Nat) -> (ws, rs : List Nat) -> LTE 1 base
                      -> LT 0 (ldet_3_2_8__hv base 0 ws) -> Ldet_3_2_8__Chunks base dv ws rs
                      -> Ldet_3_2_8__TopNonzero rs
ldet_3_2_8__chunks_top base dv ws _ h1 pos (CLast {qs} {r} tr zs) =
  TOne (replace {p = \z => LT 0 z} eq pos)
  where
    eq : ldet_3_2_8__hv base 0 ws = r
    eq = trans (ldet_3_2_8__divmod_sound base dv 0 0 r ws qs tr)
               (cong (\z => z * dv + r) (ldet_3_2_8__hv_zero base qs zs))
ldet_3_2_8__chunks_top base dv ws _ h1 pos (CMore {qs} {r} {rs} tr nz ch) =
  TMore (ldet_3_2_8__chunks_top base dv qs rs h1 (ldet_3_2_8__hv_nonzero base qs h1 nz) ch)

||| THE NUMBER 0 IS THE ONE CHUNK 0: the first pass returns 0 and leaves zero
||| limbs, so the loop stops, and fx_put_big_int prints that chunk as "0".
--@derives [LDET.3.2.8]
ldet_3_2_8__chunks_of_zero : (base, dv : Nat) -> (ws, rs : List Nat) -> LTE 1 base -> LT 0 dv
                          -> ldet_3_2_8__hv base 0 ws = 0 -> Ldet_3_2_8__Chunks base dv ws rs
                          -> rs = [0]
ldet_3_2_8__chunks_of_zero base dv ws _ h1 hd z (CLast {qs} {r} tr zs) =
  cong (\x => [x]) (trans (sym eq) z)
  where
    eq : ldet_3_2_8__hv base 0 ws = r
    eq = trans (ldet_3_2_8__divmod_sound base dv 0 0 r ws qs tr)
               (cong (\x => x * dv + r) (ldet_3_2_8__hv_zero base qs zs))
ldet_3_2_8__chunks_of_zero base dv ws _ h1 hd z (CMore {qs} {r} {rs} tr nz ch) =
  absurd (succNotLTEzero (replace {p = \x => LT 0 x} z posW))
  where
    q : Nat
    q = ldet_3_2_8__hv base 0 qs
    posW : LT 0 (ldet_3_2_8__hv base 0 ws)
    posW = replace {p = \x => LT 0 x} (sym (ldet_3_2_8__divmod_sound base dv 0 0 r ws qs tr))
             (transitive (ldet_3_2_8__hv_nonzero base qs h1 nz)
                (transitive (replace {p = \x => LTE x (q * dv)} (multOneRightNeutral q)
                               (ldet_3_2_8__mult_lte_right q 1 dv hd))
                            (lteAddRight (q * dv))))

||| A run of two passes, so the relation the theorems quantify over has one:
||| the limbs [1, 2] in base 10 are 12; divided by 7 they push 5, the
||| quotient limbs [0, 1] push 1, and 1 * 7 + 5 = 12.
--@derives [LDET.3.2.8]
ldet_3_2_8__chunks_witness : Ldet_3_2_8__Chunks 10 7 [1, 2] [5, 1]
ldet_3_2_8__chunks_witness = CMore pass1 nonzero (CLast pass2 [Refl, Refl])
  where
    pass1 : Ldet_3_2_8__DivTrace 10 7 0 [1, 2] [0, 1] 5
    pass1 = DCons {rem1 = 1} Refl (LTESucc (LTESucc LTEZero))
              (DCons {rem1 = 5} Refl
                 (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))))) DNil)
    pass2 : Ldet_3_2_8__DivTrace 10 7 0 [0, 1] [0, 0] 1
    pass2 = DCons {rem1 = 0} Refl (LTESucc LTEZero)
              (DCons {rem1 = 1} Refl (LTESucc (LTESucc LTEZero)) DNil)
    nonzero : Not (All (\w => w = 0) (the (List Nat) [0, 1]))
    nonzero (_ :: Refl :: _) impossible

-- ── the rounding is unique ──────────────────────────────────────────────────

||| Cancelling a common left summand keeps the order.
--@derives [LDET.3.2.8]
ldet_3_2_8__lte_cancel : (p, x, y : Nat) -> LTE (p + x) (p + y) -> LTE x y
ldet_3_2_8__lte_cancel Z x y le = le
ldet_3_2_8__lte_cancel (S p) x y le = ldet_3_2_8__lte_cancel p x y (fromLteSucc le)

||| Two correct roundings d + 1 steps apart squeeze d steps into nothing.
--@derives [LDET.3.2.8]
ldet_3_2_8__apart_close : (num, h, a, d : Nat)
                       -> ldet_3_2_8__rounds num h a -> ldet_3_2_8__rounds num h (a + S d)
                       -> LTE (d * (h + h)) 0
ldet_3_2_8__apart_close num h a d ((_, hiA), _) ((loB, _), _) =
  ldet_3_2_8__lte_cancel (h + h) (d * (h + h)) 0
    (replace {p = \z => LTE ((h + h) + d * (h + h)) z} (sym (plusZeroRightNeutral (h + h)))
       (ldet_3_2_8__lte_cancel (a * (h + h)) ((h + h) + d * (h + h)) (h + h)
          (transitive
             (replace {p = \z => LTE z (num + h)} (multDistributesOverPlusLeft a (S d) (h + h)) loB)
             top)))
  where
    top : LTE (num + h) (a * (h + h) + (h + h))
    top = replace {p = \z => LTE (num + h) z} (sym (plusAssociative (a * (h + h)) h h))
            (plusLteMonotoneRight h num (a * (h + h) + h) hiA)

||| Two candidate roundings a step or more apart are not both correct: two or
||| more steps apart they cannot both be near; one step apart both are ties,
||| and two consecutive numbers are not both even.
--@derives [LDET.3.2.8]
ldet_3_2_8__apart : (num, h, a, d : Nat) -> LTE 1 h
                 -> ldet_3_2_8__rounds num h a -> ldet_3_2_8__rounds num h (a + S d) -> Void
ldet_3_2_8__apart num h a (S d') h1 ra rb =
  succNotLTEzero
    (transitive (transitive (transitive h1 (lteAddRight h)) (lteAddRight (h + h)))
                (ldet_3_2_8__apart_close num h a (S d') ra rb))
ldet_3_2_8__apart num h a Z h1 ((_, hiA), tieA) ((loB, _), tieB) =
  absurd (trans (sym evenB') (trans (ldet_3_2_8__even_succ a) (cong not evenA)))
  where
    e1 : (a + S Z) * (h + h) = a * (h + h) + (h + h)
    e1 = trans (multDistributesOverPlusLeft a (S Z) (h + h))
               (cong (a * (h + h) +) (plusZeroRightNeutral (h + h)))
    top : LTE (num + h) (a * (h + h) + (h + h))
    top = replace {p = \z => LTE (num + h) z} (sym (plusAssociative (a * (h + h)) h h))
            (plusLteMonotoneRight h num (a * (h + h) + h) hiA)
    lower : LTE (a * (h + h) + (h + h)) (num + h)
    lower = replace {p = \z => LTE z (num + h)} e1 loB
    eqTop : num + h = a * (h + h) + (h + h)
    eqTop = antisymmetric top lower
    evenB : ldet_3_2_8__even (a + S Z) = True
    evenB = tieB (Left (trans e1 (sym eqTop)))
    evenA : ldet_3_2_8__even a = True
    evenA = tieA (Right (plusRightCancel num (a * (h + h) + h) h
                           (trans eqTop (plusAssociative (a * (h + h)) h h))))
    succ : a + S Z = S a
    succ = trans (sym (plusSuccRightSucc a Z)) (cong S (plusZeroRightNeutral a))
    evenB' : ldet_3_2_8__even (S a) = True
    evenB' = trans (cong ldet_3_2_8__even (sym succ)) evenB

--@derives [LDET.3.2.8]
ldet_3_2_8__rounding_unique_cmp : (num, h, k1, k2 : Nat) -> CmpNat k1 k2 -> LTE 1 h
                               -> ldet_3_2_8__rounds num h k1 -> ldet_3_2_8__rounds num h k2
                               -> k1 = k2
ldet_3_2_8__rounding_unique_cmp num h k1 _ CmpEQ h1 r1 r2 = Refl
ldet_3_2_8__rounding_unique_cmp num h k1 _ (CmpLT d) h1 r1 r2 =
  absurd (ldet_3_2_8__apart num h k1 d h1 r1 r2)
ldet_3_2_8__rounding_unique_cmp num h _ k2 (CmpGT d) h1 r1 r2 =
  absurd (ldet_3_2_8__apart num h k2 d h1 r2 r1)

||| THE ROUNDING IS UNIQUE. Two answers both nearest, and even at a tie, are
||| one: so `ldet_3_2_8__rounds` determines what the plan must keep, and the
||| formula the code uses is the only one that satisfies it.
--@derives [LDET.3.2.8]
ldet_3_2_8__rounding_unique : (num, h, k1, k2 : Nat) -> LTE 1 h
                           -> ldet_3_2_8__rounds num h k1 -> ldet_3_2_8__rounds num h k2
                           -> k1 = k2
ldet_3_2_8__rounding_unique num h k1 k2 h1 r1 r2 =
  ldet_3_2_8__rounding_unique_cmp num h k1 k2 (cmp k1 k2) h1 r1 r2

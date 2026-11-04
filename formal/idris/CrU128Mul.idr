-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Lemma B of the cr_u128 review: the two multiplication shapes of
||| the probe's Cryptol proof (cr_u128.cry, in the private tree) are the product.
|||
||| EVIDENCE FOR A REVIEW, NOT A MODEL OF A CLAUSE. cr_u128.hpp is a portable
||| unsigned 128-bit integer, two 64-bit halves, so that CORE-MATH's eight
||| 128-bit functions build on Xtensa, where no compiler has the type. No
||| clause governs it, so every element here is a gap. Lemma A (cr_u128_mul.saw, the Implementer's) says the class's code IS
||| the two shapes; this file says the shapes ARE the product. Only the two
||| together say the class multiplies, and the review says so.
|||
||| THE BASE IS ANY NATURAL. Cryptol computes on [64] and [128]; here the base
||| `m` is a variable, and 2^32 (schoolbook64's half word) and 2^64
||| (mul128_halves' half word) are instances. Nothing here computes a large
||| number: every proof is a term over Nat that the checker normalises at once.
|||
||| THE FIRST SHAPE, schoolbook64, a 64 x 64 -> 128 product from four 32 x 32
||| partial products:
|||     (a1*m + a0) * (b1*m + b0) = a1*b1*(m*m) + a0*b1*m + a1*b0*m + a0*b0.
||| `gap__schoolbook` is that identity, over any naturals (B1). Why none of
||| the Cryptol operations wraps is B2: with the four digits below m, each
||| partial product is below m*m (`gap__product_below_square`), so it fits a
||| 64-bit word when m = 2^32; each operand is below m*m
||| (`gap__digits_below_square`), so the product is below (m*m)*(m*m)
||| (`gap__schoolbook_fits`), which fits 128 bits. Under those bounds the
||| Cryptol expression, read as arithmetic, is the Nat expression.
|||
||| THE SECOND SHAPE, mul128_halves, a 128 x 128 -> 128 product mod 2^128 from
||| 64-bit halves. It wraps on purpose, twice: the cross-term sum
||| `alo*bhi + ahi*blo` is a [64] sum, and the final [128] addition wraps. Each
||| wrapping operation is taken by its DEFINING EQUATION -- a quotient and a
||| remainder below the modulus -- so `div` and `mod` never appear (they do not
||| reduce during elaboration; Protobuf/Wire.idr records it). B3,
||| `gap__halves`: given the two equations, the product is
||| (ahi*bhi + q + q2)*(m*m) + res. B4, `gap__remainder_unique`: two
||| decompositions of one number with remainders below the modulus have one
||| remainder. Together, `gap__halves_mod`: whatever quotient the true product
||| has, its remainder mod m*m is `res`, the shape's result. The bound r < m
||| that the [64] wrap gives is not needed for that and is not a hypothesis.
|||
||| WHAT THIS DOES NOT ESTABLISH. That these Nat expressions are the Cryptol
||| shapes. The shapes are Cryptol's, in cr_u128.cry; the transcription here
||| is read against them and checked by nobody. The verdict names that residue
||| (its §4), and the Implementer's two checks on the Cryptol side, `:check`
||| and a solver proof at small widths, narrow it.
|||
||| THE BASE LIBRARY. Data.Nat's ring lemmas do the rewriting; there is no ring
||| solver, so every identity is a chain of `trans` and `cong`, each step typed
||| so the checker names the one that fails. Monotonicity of multiplication
||| under LTE is proved here by induction (`gap__mult_lte_left`,
||| `gap__mult_lte_right`), because the base's name for it was not confirmed
||| in 0.8.0; replace them by the base's if it has one.
module CrU128Mul

import Data.Nat

%default total
%unbound_implicits off

||| The first shape: four partial products in their places, over any base.
--@gap
gap__shape : (m, a1, a0, b1, b0 : Nat) -> Nat
gap__shape m a1 a0 b1 b0 = a1*b1*(m*m) + a0*b1*m + a1*b0*m + a0*b0

||| Two products of digit and base: the bases pair off.
--@gap
gap__mult_pair : (a, m, b : Nat) -> (a*m)*(b*m) = (a*b)*(m*m)
gap__mult_pair a m b =
  trans (sym (multAssociative a m (b*m)))
  (trans (cong (a *) (multAssociative m b m))
  (trans (cong (a *) (cong (* m) (multCommutative m b)))
  (trans (cong (a *) (sym (multAssociative b m m)))
         (multAssociative a b (m*m)))))

||| The base moves past a factor.
--@gap
gap__mult_swap : (a, m, b : Nat) -> (a*m)*b = (a*b)*m
gap__mult_swap a m b =
  trans (sym (multAssociative a m b))
  (trans (cong (a *) (multCommutative m b))
         (multAssociative a b m))

||| B1. The first shape is the product, over any naturals: a ring identity.
--@gap
gap__schoolbook : (m, a1, a0, b1, b0 : Nat)
               -> (a1*m + a0) * (b1*m + b0) = gap__shape m a1 a0 b1 b0
gap__schoolbook m a1 a0 b1 b0 =
  trans (multDistributesOverPlusRight (a1*m + a0) (b1*m) b0)
  (trans (cong2 (+) (multDistributesOverPlusLeft (a1*m) a0 (b1*m))
                    (multDistributesOverPlusLeft (a1*m) a0 b0))
  (trans (cong2 (+) (cong2 (+) (gap__mult_pair a1 m b1) (multAssociative a0 b1 m))
                    (cong (+ (a0*b0)) (gap__mult_swap a1 m b0)))
         (plusAssociative (a1*b1*(m*m) + a0*b1*m) (a1*b0*m) (a0*b0))))

||| Multiplication on the right keeps the order, by induction on the proof.
--@gap
gap__mult_lte_left : (a, b, c : Nat) -> LTE a b -> LTE (a*c) (b*c)
gap__mult_lte_left Z b c LTEZero = LTEZero
gap__mult_lte_left (S a) (S b) c (LTESucc le) =
  plusLteMonotoneLeft c (a*c) (b*c) (gap__mult_lte_left a b c le)

||| Multiplication on the left keeps the order, from the right form.
--@gap
gap__mult_lte_right : (c, a, b : Nat) -> LTE a b -> LTE (c*a) (c*b)
gap__mult_lte_right c a b le =
  replace {p = \z => LTE z (c*b)} (multCommutative a c)
    (replace {p = \z => LTE (a*c) z} (multCommutative b c)
       (gap__mult_lte_left a b c le))

||| B2. A product of two values below the base is below its square: at
||| m = 2^32 each 32 x 32 partial product fits a 64-bit word.
--@gap
gap__product_below_square : (m, x, y : Nat) -> LT x m -> LT y m -> LT (x*y) (m*m)
gap__product_below_square m x y hx hy =
  transitive (LTESucc step)
    (transitive (gap__mult_lte_left (S x) m (S y) hx)
                (gap__mult_lte_right m (S y) m hy))
  where
    step : LTE (x*y) (y + x*(S y))
    step = transitive (gap__mult_lte_right x y (S y) (lteSuccRight reflexive))
             (replace {p = \z => LTE (x*(S y)) z} (plusCommutative (x*(S y)) y)
                (lteAddRight (x*(S y))))

||| B2. Two digits below the base make a number below its square: at
||| m = 2^32 a 64-bit operand, at m = 2^64 a 128-bit one.
--@gap
gap__digits_below_square : (m, a1, a0 : Nat) -> LT a1 m -> LT a0 m -> LT (a1*m + a0) (m*m)
gap__digits_below_square m a1 a0 h1 h0 =
  replace {p = \z => LTE z (m*m)} (sym (plusSuccRightSucc (a1*m) a0))
    (transitive (plusLteMonotoneLeft (a1*m) (S a0) m h0)
       (replace {p = \z => LTE z (m*m)} (plusCommutative m (a1*m))
          (gap__mult_lte_left (S a1) m m h1)))

||| B2. The product of two two-digit numbers is below the fourth power of the
||| base: at m = 2^32 it fits 128 bits, so the final sum does not wrap either.
--@gap
gap__schoolbook_fits : (m, a1, a0, b1, b0 : Nat)
                    -> LT a1 m -> LT a0 m -> LT b1 m -> LT b0 m
                    -> LT ((a1*m + a0) * (b1*m + b0)) ((m*m)*(m*m))
gap__schoolbook_fits m a1 a0 b1 b0 h1 h0 k1 k0 =
  gap__product_below_square (m*m) (a1*m + a0) (b1*m + b0)
    (gap__digits_below_square m a1 a0 h1 h0)
    (gap__digits_below_square m b1 b0 k1 k0)

||| B3. The second shape. `e1` is the [64] cross-term sum by its defining
||| equation, `e2` the [128] addition by its own; the product is then the
||| stated multiple of m*m plus the shape's result.
--@gap
gap__halves : (m, ahi, alo, bhi, blo, q, r, q2, res : Nat)
           -> alo*bhi + ahi*blo = q*m + r
           -> alo*blo + r*m = q2*(m*m) + res
           -> (ahi*m + alo) * (bhi*m + blo) = (ahi*bhi + q + q2) * (m*m) + res
gap__halves m ahi alo bhi blo q r q2 res e1 e2 =
  trans s0 (trans s1 (trans s2 (trans s3 (trans s4 (trans s5 (trans s6
    (trans s7 (trans s8 (trans s9 (trans s10 (trans s11 s12)))))))))))
  where
    s0 : (ahi*m + alo) * (bhi*m + blo)
       = ((ahi*bhi*(m*m) + alo*bhi*m) + ahi*blo*m) + alo*blo
    s0 = gap__schoolbook m ahi alo bhi blo
    s1 : ((ahi*bhi*(m*m) + alo*bhi*m) + ahi*blo*m) + alo*blo
       = (ahi*bhi*(m*m) + (alo*bhi*m + ahi*blo*m)) + alo*blo
    s1 = cong (+ (alo*blo)) (sym (plusAssociative (ahi*bhi*(m*m)) (alo*bhi*m) (ahi*blo*m)))
    s2 : (ahi*bhi*(m*m) + (alo*bhi*m + ahi*blo*m)) + alo*blo
       = (ahi*bhi*(m*m) + (alo*bhi + ahi*blo)*m) + alo*blo
    s2 = cong (+ (alo*blo)) (cong ((ahi*bhi*(m*m)) +)
           (sym (multDistributesOverPlusLeft (alo*bhi) (ahi*blo) m)))
    s3 : (ahi*bhi*(m*m) + (alo*bhi + ahi*blo)*m) + alo*blo
       = (ahi*bhi*(m*m) + (q*m + r)*m) + alo*blo
    s3 = cong (+ (alo*blo)) (cong ((ahi*bhi*(m*m)) +) (cong (* m) e1))
    s4 : (ahi*bhi*(m*m) + (q*m + r)*m) + alo*blo
       = (ahi*bhi*(m*m) + ((q*m)*m + r*m)) + alo*blo
    s4 = cong (+ (alo*blo)) (cong ((ahi*bhi*(m*m)) +) (multDistributesOverPlusLeft (q*m) r m))
    s5 : (ahi*bhi*(m*m) + ((q*m)*m + r*m)) + alo*blo
       = (ahi*bhi*(m*m) + (q*(m*m) + r*m)) + alo*blo
    s5 = cong (+ (alo*blo)) (cong ((ahi*bhi*(m*m)) +)
           (cong (+ (r*m)) (sym (multAssociative q m m))))
    s6 : (ahi*bhi*(m*m) + (q*(m*m) + r*m)) + alo*blo
       = ((ahi*bhi*(m*m) + q*(m*m)) + r*m) + alo*blo
    s6 = cong (+ (alo*blo)) (plusAssociative (ahi*bhi*(m*m)) (q*(m*m)) (r*m))
    s7 : ((ahi*bhi*(m*m) + q*(m*m)) + r*m) + alo*blo
       = (ahi*bhi*(m*m) + q*(m*m)) + (r*m + alo*blo)
    s7 = sym (plusAssociative (ahi*bhi*(m*m) + q*(m*m)) (r*m) (alo*blo))
    s8 : (ahi*bhi*(m*m) + q*(m*m)) + (r*m + alo*blo)
       = (ahi*bhi*(m*m) + q*(m*m)) + (alo*blo + r*m)
    s8 = cong ((ahi*bhi*(m*m) + q*(m*m)) +) (plusCommutative (r*m) (alo*blo))
    s9 : (ahi*bhi*(m*m) + q*(m*m)) + (alo*blo + r*m)
       = (ahi*bhi*(m*m) + q*(m*m)) + (q2*(m*m) + res)
    s9 = cong ((ahi*bhi*(m*m) + q*(m*m)) +) e2
    s10 : (ahi*bhi*(m*m) + q*(m*m)) + (q2*(m*m) + res)
        = ((ahi*bhi*(m*m) + q*(m*m)) + q2*(m*m)) + res
    s10 = plusAssociative (ahi*bhi*(m*m) + q*(m*m)) (q2*(m*m)) res
    s11 : ((ahi*bhi*(m*m) + q*(m*m)) + q2*(m*m)) + res
        = ((ahi*bhi + q)*(m*m) + q2*(m*m)) + res
    s11 = cong (+ res) (cong (+ (q2*(m*m)))
            (sym (multDistributesOverPlusLeft (ahi*bhi) q (m*m))))
    s12 : ((ahi*bhi + q)*(m*m) + q2*(m*m)) + res
        = (ahi*bhi + q + q2) * (m*m) + res
    s12 = cong (+ res) (sym (multDistributesOverPlusLeft (ahi*bhi + q) q2 (m*m)))

||| B4, by the order of the two quotients: equal, and the remainders cancel;
||| one below the other, and the larger side is at least a whole modulus
||| ahead, which a remainder below the modulus cannot make up.
--@gap
gap__remainder_unique_cmp : (n, k, k2, res, res2 : Nat) -> CmpNat k k2
                         -> LT res n -> LT res2 n
                         -> k*n + res = k2*n + res2 -> res = res2
gap__remainder_unique_cmp n k _ res res2 CmpEQ hr hr2 eq =
  plusLeftCancel (k*n) res res2 eq
gap__remainder_unique_cmp n k _ res res2 (CmpLT d) hr hr2 eq =
  absurd (succNotLTEpred (transitive hr ge))
  where
    e3 : res = (n + d*n) + res2
    e3 = plusLeftCancel (k*n) res ((n + d*n) + res2)
           (trans eq (trans (cong (+ res2) (multDistributesOverPlusLeft k (S d) n))
                            (sym (plusAssociative (k*n) (n + d*n) res2))))
    ge : LTE n res
    ge = replace {p = \z => LTE n z} (sym e3)
           (transitive (lteAddRight n) (lteAddRight (n + d*n)))
gap__remainder_unique_cmp n _ k2 res res2 (CmpGT d) hr hr2 eq =
  absurd (succNotLTEpred (transitive hr2 ge))
  where
    e3 : (n + d*n) + res = res2
    e3 = plusLeftCancel (k2*n) ((n + d*n) + res) res2
           (trans (plusAssociative (k2*n) (n + d*n) res)
                  (trans (sym (cong (+ res) (multDistributesOverPlusLeft k2 (S d) n))) eq))
    ge : LTE n res2
    ge = replace {p = \z => LTE n z} e3
           (transitive (lteAddRight n) (lteAddRight (n + d*n)))

||| B4. Two decompositions of one number with remainders below the modulus
||| have one remainder.
--@gap
gap__remainder_unique : (n, k, k2, res, res2 : Nat) -> LT res n -> LT res2 n
                     -> k*n + res = k2*n + res2 -> res = res2
gap__remainder_unique n k k2 res res2 hr hr2 eq =
  gap__remainder_unique_cmp n k k2 res res2 (cmp k k2) hr hr2 eq

||| B3 and B4 together: however the true product is written as a multiple of
||| m*m plus a remainder below m*m, that remainder is the shape's result.
--@gap
gap__halves_mod : (m, ahi, alo, bhi, blo, q, r, q2, res, qp, rp : Nat)
               -> alo*bhi + ahi*blo = q*m + r
               -> alo*blo + r*m = q2*(m*m) + res -> LT res (m*m)
               -> (ahi*m + alo) * (bhi*m + blo) = qp*(m*m) + rp -> LT rp (m*m)
               -> rp = res
gap__halves_mod m ahi alo bhi blo q r q2 res qp rp e1 e2 hres e3 hrp =
  gap__remainder_unique (m*m) qp (ahi*bhi + q + q2) rp res hrp hres
    (trans (sym e3) (gap__halves m ahi alo bhi blo q r q2 res e1 e2))

||| THE HYPOTHESES OF LEMMA B CAN BE MET, at base ten, and its conclusion
||| then holds, each computed: 12 x 34, halves (1, 2) and (3, 4); the
||| cross-term sum 2*3 + 1*4 = 10 is 1*10 + 0 (q = 1, r = 0); the low product
||| plus the carried remainder, 8 + 0, is 0*100 + 8 (q2 = 0, res = 8); and
||| the product, 408, is (1*3 + 1 + 0)*100 + 8, B3's right-hand side. Three
||| closed equations the checker evaluates. The theorem is not applied at
||| these literals: in 0.8.0 a type obtained by instantiating it does not
||| normalise against a literal (the unifier left `mult 9 10` as a Peano
||| term beside 408). The theorem is for every base and every operand; this
||| is the one point at which its premises are seen to be satisfiable.
--@gap
gap__halves_at_ten : ( 2*3 + 1*4 = 1*10 + 0
                     , 2*4 + 0*10 = 0*(10*10) + 8
                     , (1*10 + 2) * (3*10 + 4) = (1*3 + 1 + 0) * (10*10) + 8 )
gap__halves_at_ten = (Refl, Refl, Refl)

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A PROGRAM THAT CARRIES THE TERMINATION CERTIFICATE, built: the witness
||| that the hypothesis of the termination theorems can be met by a program
||| that does something.
|||
||| NORMATIVE COMPANION to Lcyc/Certificate.idr and Lcyc/TmsTermination.idr.
||| Every theorem that takes `Lcyc_3_1_1__certified` or
||| `Lcyc_3_1_1__certified_tms` is stated for every program carrying one. The
||| records' fields are quantified over the program's rules, so the program
||| with no rules carries one trivially; this module builds one for a program
||| with two rules in two strata, the second reading what the first emits.
|||
||| THE PROGRAM (`lcyc_3_1_1__chain`), over three kinds:
|||
|||   rule 0   matches kind 0, emits kind 1
|||   rule 1   matches kind 1, emits kind 2
|||
||| Each emit is a literal, each kind a `logical` relation, and neither rule
||| has a `no` pattern. Rule 0 is stratum 0 and rule 1 is stratum 1.
|||
||| PROVED of it, each a field of the certificate: every edge respects the
||| strata (`lcyc_3_1__chain_edge_mono`: the one edge is from rule 0 to rule
||| 1, and rule 1 writes nothing rule 0 reads); every rule has a stratum
||| (`lcyc_3_1__chain_in_range`); no stratum reads a kind it emits
||| (`lcyc_3_1_1__chain_no_emit_read`), which is [LCYC.3.1.1]'s condition
||| with one stratum per SCC; every emitted value is a literal
||| (`lcyc_3_1_1__chain_range`); and the program is positive
||| (`iret_7_9__chain_positive`).
|||
||| THE WITNESSES. `lcyc_3_1_1__chain_is_certified_tms` and
||| `lcyc_3_1_1__chain_is_certified` are the two certificates, inhabited.
||| `lcyc_1_1__chain_terminates` and `lcyc_1_1__chain_terminates_tms` are the
||| two termination theorems applied to the program: from every input it
||| reaches an empty agenda, on the plain engine and with logical retraction
||| in the loop.
|||
||| NOT CLAIMED. That the certificate admits every program [LCYC.3.1.1]
||| admits: that is Lcyc/Certificate.idr's header, by argument. One program
||| shows the hypothesis is not empty, and no more.
module Lcyc.CertifiedWitness

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.TmsBridge
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Data.List
import Data.List.Elem
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The program
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
||| The value both rules emit: a literal.
public export
lcyc_3_1_1__chain_val : List Lfac_1_7_1__fact -> (Nat, Nat)
lcyc_3_1_1__chain_val _ = (0, 0)

--@derives [LCYC.3.1.1]
||| No `where`: every match is admitted.
public export
lcyc_3_1_1__chain_guard : List Lfac_1_7_1__fact -> Bool
lcyc_3_1_1__chain_guard _ = True

--@derives [LCYC.3.1.1]
||| Rule 0: matches kind 0, emits kind 1.
public export
lcyc_3_1_1__chain_r0 : Lgra_6_1__rule
lcyc_3_1_1__chain_r0 = MkRule [0] lcyc_3_1_1__chain_guard [] [Emit 1 lcyc_3_1_1__chain_val]

--@derives [LCYC.3.1.1]
||| Rule 1: matches kind 1, emits kind 2.
public export
lcyc_3_1_1__chain_r1 : Lgra_6_1__rule
lcyc_3_1_1__chain_r1 = MkRule [1] lcyc_3_1_1__chain_guard [] [Emit 2 lcyc_3_1_1__chain_val]

--@derives [LCYC.3.1.1]
||| Every kind a `logical` relation.
public export
lcyc_3_1_1__chain_life : Nat -> Lscp_1_3__lifecycle
lcyc_3_1_1__chain_life _ = Relation

--@derives [LCYC.3.1.1]
||| THE PROGRAM: the two rules, in order.
public export
lcyc_3_1_1__chain : Lcyc_3_2_1__program
lcyc_3_1_1__chain = MkProgram lcyc_3_1_1__chain_life [lcyc_3_1_1__chain_r0, lcyc_3_1_1__chain_r1]

--@derives [LCYC.3.1]
||| Rule 0 is stratum 0; every later rule is stratum 1.
public export
lcyc_3_1__chain_strat : Nat -> Nat
lcyc_3_1__chain_strat Z = 0
lcyc_3_1__chain_strat (S _) = 1

--@derives [LCYC.3.1]
||| The stratification: two strata.
public export
lcyc_3_1__chain_strata : Lcyc_3_1__strata
lcyc_3_1__chain_strata = MkStrata 2 lcyc_3_1__chain_strat

-- ---------------------------------------------------------------------
-- Kinds told apart
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1]
||| No kind is both 2 and 0.
export
lcyc_3_1__two_is_not_zero : (k : Nat) -> rarc_5_6_5__elem k [2] = True -> rarc_5_6_5__elem k [0] = True -> Void
lcyc_3_1__two_is_not_zero Z Refl _ impossible
lcyc_3_1__two_is_not_zero (S Z) Refl _ impossible
lcyc_3_1__two_is_not_zero (S (S Z)) _ Refl impossible
lcyc_3_1__two_is_not_zero (S (S (S _))) Refl _ impossible

--@derives [LCYC.3.1.1]
||| A kind that is 1 is not 0.
export
lcyc_3_1_1__one_is_not_zero : (k : Nat) -> rarc_5_6_5__elem k [1] = True -> rarc_5_6_5__elem k [0] = False
lcyc_3_1_1__one_is_not_zero Z Refl impossible
lcyc_3_1_1__one_is_not_zero (S Z) _ = Refl
lcyc_3_1_1__one_is_not_zero (S (S _)) Refl impossible

--@derives [LCYC.3.1.1]
||| A kind that is 2 is not 1.
export
lcyc_3_1_1__two_is_not_one : (k : Nat) -> rarc_5_6_5__elem k [2] = True -> rarc_5_6_5__elem k [1] = False
lcyc_3_1_1__two_is_not_one Z Refl impossible
lcyc_3_1_1__two_is_not_one (S Z) Refl impossible
lcyc_3_1_1__two_is_not_one (S (S Z)) _ = Refl
lcyc_3_1_1__two_is_not_one (S (S (S _))) Refl impossible

--@derives [LCYC.3.1.1]
||| The one member of a one-element list.
export
lcyc_3_1_1__only_member : {0 a : Type} -> {0 x, y : a} -> Elem x [y] -> x = y
lcyc_3_1_1__only_member Here = Refl
lcyc_3_1_1__only_member (There e) = absurd e

--@derives [LCYC.3.1.1]
||| Two equal emits carry one value function.
export
lcyc_3_1_1__emit_value : {0 k, k0 : Nat} -> {0 v, v0 : List Lfac_1_7_1__fact -> (Nat, Nat)} -> Emit k v = Emit k0 v0 -> v = v0
lcyc_3_1_1__emit_value Refl = Refl

-- ---------------------------------------------------------------------
-- The certificate's fields
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1]
||| EVERY EDGE RESPECTS THE STRATA. The one edge is from rule 0 to rule 1;
||| an edge back would need a kind rule 1 writes and rule 0 reads, and
||| there is none.
export
lcyc_3_1__chain_edge_mono : Lcyc_3_1__edge_mono lcyc_3_1__chain_strata (rules lcyc_3_1_1__chain)
lcyc_3_1__chain_edge_mono Z Z _ _ _ _ _ _ _ = LTEZero
lcyc_3_1__chain_edge_mono Z (S Z) _ _ _ _ _ _ _ = LTEZero
lcyc_3_1__chain_edge_mono Z (S (S Z)) _ _ _ Refl _ _ _ impossible
lcyc_3_1__chain_edge_mono Z (S (S (S _))) _ _ _ Refl _ _ _ impossible
lcyc_3_1__chain_edge_mono (S Z) Z _ _ Refl Refl k wk rk = void (lcyc_3_1__two_is_not_zero k wk rk)
lcyc_3_1__chain_edge_mono (S Z) (S Z) _ _ _ _ _ _ _ = LTESucc LTEZero
lcyc_3_1__chain_edge_mono (S Z) (S (S Z)) _ _ _ Refl _ _ _ impossible
lcyc_3_1__chain_edge_mono (S Z) (S (S (S _))) _ _ _ Refl _ _ _ impossible
lcyc_3_1__chain_edge_mono (S (S Z)) _ _ _ Refl _ _ _ _ impossible
lcyc_3_1__chain_edge_mono (S (S (S _))) _ _ _ Refl _ _ _ _ impossible

--@derives [LCYC.3.1]
||| Every rule has a stratum below the count.
export
lcyc_3_1__chain_in_range : Lcyc_3_1__in_range lcyc_3_1__chain_strata (rules lcyc_3_1_1__chain)
lcyc_3_1__chain_in_range Z _ _ = LTESucc LTEZero
lcyc_3_1__chain_in_range (S Z) _ _ = LTESucc (LTESucc LTEZero)
lcyc_3_1__chain_in_range (S (S Z)) _ Refl impossible
lcyc_3_1__chain_in_range (S (S (S _))) _ Refl impossible

--@derives [LCYC.3.1.1]
||| NO STRATUM READS A KIND IT EMITS: stratum 0 emits kind 1 and reads kind
||| 0, stratum 1 emits kind 2 and reads kind 1, and no later stratum has a
||| rule.
export
lcyc_3_1_1__chain_no_emit_read : (i, k : Nat) ->
  rarc_5_6_5__elem k (lcyc_3_1__emit_kinds_of lcyc_3_1__chain_strata i (rules lcyc_3_1_1__chain)) = True ->
  rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of lcyc_3_1__chain_strata i (rules lcyc_3_1_1__chain)) = False
lcyc_3_1_1__chain_no_emit_read Z k ek = lcyc_3_1_1__one_is_not_zero k ek
lcyc_3_1_1__chain_no_emit_read (S Z) k ek = lcyc_3_1_1__two_is_not_one k ek
lcyc_3_1_1__chain_no_emit_read (S (S _)) _ Refl impossible

--@derives [LCYC.3.1.1]
||| Every emitted value is the program's one literal.
export
lcyc_3_1_1__chain_range : Lcyc_3_1_1__range lcyc_3_1_1__chain [(0, 0)]
lcyc_3_1_1__chain_range Z _ Refl k v e fs = rewrite lcyc_3_1_1__emit_value (lcyc_3_1_1__only_member e) in Left Here
lcyc_3_1_1__chain_range (S Z) _ Refl k v e fs = rewrite lcyc_3_1_1__emit_value (lcyc_3_1_1__only_member e) in Left Here
lcyc_3_1_1__chain_range (S (S Z)) _ Refl _ _ _ _ impossible
lcyc_3_1_1__chain_range (S (S (S _))) _ Refl _ _ _ _ impossible

--@derives [IRET.7.9]
||| The program is positive: neither rule has a `no` pattern.
export
iret_7_9__chain_positive : Iret_7_9__positive lcyc_3_1_1__chain
iret_7_9__chain_positive Z _ Refl = Refl
iret_7_9__chain_positive (S Z) _ Refl = Refl
iret_7_9__chain_positive (S (S Z)) _ Refl impossible
iret_7_9__chain_positive (S (S (S _))) _ Refl impossible

-- ---------------------------------------------------------------------
-- The witnesses
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
||| THE CERTIFICATE WITH TRUTH MAINTENANCE IS INHABITED, by a program with
||| two strata and an emit a later stratum reads.
export
lcyc_3_1_1__chain_is_certified_tms : Lcyc_3_1_1__certified_tms lcyc_3_1_1__chain
lcyc_3_1_1__chain_is_certified_tms =
  MkCertifiedTms lcyc_3_1__chain_strata [(0, 0)] lcyc_3_1__chain_edge_mono lcyc_3_1__chain_in_range
                 lcyc_3_1_1__chain_no_emit_read lcyc_3_1_1__chain_range

--@derives [LCYC.3.1.1]
||| THE CORE CERTIFICATE IS INHABITED, by the same program.
export
lcyc_3_1_1__chain_is_certified : Lcyc_3_1_1__certified lcyc_3_1_1__chain
lcyc_3_1_1__chain_is_certified = lcyc_3_1_1__tms_to_core lcyc_3_1_1__chain lcyc_3_1_1__chain_is_certified_tms

--@derives [LCYC.1.1]
||| THE TERMINATION THEOREM, AT AN INSTANCE: the program reaches an empty
||| agenda from every input working memory.
export
lcyc_1_1__chain_terminates : (wm0 : Rarc_5_6_4__wm) ->
  (n : Nat ** iret_11_4__step_n lcyc_3_1_1__chain n (rarc_5_6_5__init_state lcyc_3_1_1__chain wm0) = Nothing)
lcyc_1_1__chain_terminates wm0 = lcyc_1_1__certified_terminates lcyc_3_1_1__chain lcyc_3_1_1__chain_is_certified wm0

--@derives [LCYC.1.1]
||| THE SAME WITH TRUTH MAINTENANCE: from every input with unique ids, with
||| logical retraction in the loop.
export
lcyc_1_1__chain_terminates_tms : (wm0 : Rarc_5_6_4__wm) -> Iret_4_4__unique wm0 ->
  (n : Nat ** iret_11_4__step_n_tms lcyc_3_1_1__chain n (rarc_5_6_5__init_tms lcyc_3_1_1__chain wm0) = Nothing)
lcyc_1_1__chain_terminates_tms wm0 uniq =
  lcyc_1_1__certified_terminates_tms lcyc_3_1_1__chain iret_7_9__chain_positive lcyc_3_1_1__chain_is_certified_tms wm0 uniq

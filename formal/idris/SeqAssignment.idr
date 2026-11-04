-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| `seq` assignment in the serial consumption loop ([RARC.5.6.9]).
|||
||| THE CLAUSE: "The loop is **strictly serial**… Parallelism within a single
||| consumption loop is forbidden at the event level — `seq` assignment happens
||| at step (1) and must be monotonic."
|||
||| This is the third face of the determinism story the other two modules take
||| apart. `Replay.idr` refuted [RARC.5.6.10]'s IMPLICATION — loop determinism
||| does not give byte-identical replay. `CapBreach.idr` attacked its
||| ANTECEDENT — `pump_wcet_ns` is an output that is not a function of the
||| program. This one asks what [RARC.5.6.9] actually buys, and the answer is
||| that it buys something real.
|||
||| WHAT IS PROVEN: the sequence of `seq` values a pass assigns depends only on
||| the starting counter and HOW MANY events there were — never on what the
||| events are. That is the usable form of "monotonic": it makes `seq` a
||| positional index into the stream rather than a property of the payload, so
||| two runs over the same number of events agree on every `seq` before either
||| looks at a payload.
|||
||| WHY THAT IS THE RIGHT STATEMENT and not "the list is increasing". Increasing
||| would be satisfied by an assignment that skipped, or that depended on the
||| event — `seq = hash(payload)` sorted ascending is monotonic and useless.
||| Positionality is what a replayer needs, and it is strictly stronger.
|||
||| WHAT THIS DOES NOT ESTABLISH, which is why the tie is `partial`: that the
||| loop's OUTPUT is deterministic. Positional `seq` orders the events
||| identically in both runs and says nothing about what processing each event
||| produces. [RARC.5.6.10] needs the second half and the corpus does not supply
||| it — see `Replay.idr` and `CapBreach.idr` for two places it demonstrably
||| fails.
module SeqAssignment

%default total

--@spec [RARC.5.6.9]
||| Step (1): pull the next event and stamp it. Serial by construction — there
||| is one counter and it advances once per event, which is what "parallelism
||| within a single consumption loop is forbidden at the event level" forbids
||| any other shape of.
|||
||| Events are modelled as opaque payloads. Nothing below reads one, and that is
||| the point rather than a simplification.
rarc_5_6_9__assign : (next : Nat) -> List Nat -> List (Nat, Nat)
rarc_5_6_9__assign _ []        = []
rarc_5_6_9__assign n (e :: es) = (n, e) :: rarc_5_6_9__assign (S n) es

--@spec [RARC.5.6.9]
||| Just the `seq` values a pass assigned, in order.
rarc_5_6_9__seqs : (next : Nat) -> List Nat -> List Nat
rarc_5_6_9__seqs n es = map fst (rarc_5_6_9__assign n es)

--@spec [RARC.5.6.9]
||| The sequence a monotonic counter produces: `start, start+1, start+2, …`,
||| one per event. Defined independently of `assign` so the theorem below has
||| something to be a theorem ABOUT — if it were derived from `assign` it would
||| restate it rather than check it.
rarc_5_6_9__count_from : (start : Nat) -> (howMany : Nat) -> List Nat
rarc_5_6_9__count_from _ Z     = []
rarc_5_6_9__count_from n (S k) = n :: rarc_5_6_9__count_from (S n) k

--@derives [RARC.5.6.9]
||| `seq` IS POSITIONAL: the values assigned depend only on the starting counter
||| and the number of events, never on the events themselves.
|||
||| This is monotonicity in the form a replayer can use. Two runs that see the
||| same NUMBER of events agree on every `seq`, before either looks at a
||| payload — so `seq` is an index into the stream rather than a fact about its
||| contents, and a stream can be replayed positionally.
rarc_5_6_9__seq_is_positional :
  (n : Nat) -> (es : List Nat) ->
  rarc_5_6_9__seqs n es = rarc_5_6_9__count_from n (length es)
rarc_5_6_9__seq_is_positional n []        = Refl
rarc_5_6_9__seq_is_positional n (e :: es) =
  cong (\xs => n :: xs) (rarc_5_6_9__seq_is_positional (S n) es)

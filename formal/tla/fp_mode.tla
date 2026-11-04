-------------------------------- MODULE fp_mode --------------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* The floating-point rounding mode as state the engine and the integrator *)
(* share on one thread ([LDET.3.6.1], [NDET.1.3]), as a SAFETY spec        *)
(* (TLA+ / TLC).                                                           *)
(*                                                                         *)
(* NORMATIVE COMPANION, named and tagged as pump_single_writer.tla says:   *)
(* every operator is <lowercased-clause-id>__<Tag>, with the clause        *)
(* repeated above it.                                                       *)
(*                                                                         *)
(* THE MODEL. One thread, so one hardware mode. Control is a stack of      *)
(* frames: integrator code, or an engine call. The integrator may set any  *)
(* mode at any time it runs, may call any engine that is not already       *)
(* running ([NLFC.3.3]), and from inside a callback may call another       *)
(* engine. An engine call records the mode it found, establishes           *)
(* round-to-nearest-even, and evaluates; it hands control back to the      *)
(* integrator in two ways -- a callback, or its return -- and each time    *)
(* first restores the mode it found. When a callback returns, the engine   *)
(* establishes round-to-nearest-even again before it evaluates.            *)
(*                                                                         *)
(* THE GUARANTEE, as two invariants over every interleaving TLC reaches:   *)
(*   - every engine `Float` operation runs in round-to-nearest-even        *)
(*     (`ldet_3_6_1__engine_runs_rne`);                                    *)
(*   - integrator code only ever sees its own mode: the mode it set at     *)
(*     that level, or held when it called in (`ldet_3_6_1__integrator_    *)
(*     sees_own`).                                                         *)
(*                                                                         *)
(* A READING. The mode an engine restores is the one the integrator held   *)
(* when it called in. A mode the integrator sets inside a callback is that *)
(* callback's: the engine re-establishes its own mode when the callback    *)
(* returns, and on its own return restores the caller's, not the           *)
(* callback's. [LDET.3.6.1] says "restore the integrator's mode", and this *)
(* is the reading in which no integrator frame sees another's mode.        *)
(*                                                                         *)
(* NOT MODELLED. Which modes exist beyond "the engine's" and "others"      *)
(* (three suffice: the engine's and two that differ); exceptions flags     *)
(* ([LDET.3.6.2]: none observable); signals and threads other than this    *)
(* one; how the engine sets the mode (fesetround or a direct write).       *)
(*                                                                         *)
(* TEETH. Drop the restore from `ldet_3_6_1__Callback` and                 *)
(* `integrator_sees_own` fails at the callback's first state. Drop the     *)
(* re-establish from `ldet_3_6_1__CallbackReturn` and `engine_runs_rne`    *)
(* fails: the integrator sets another mode inside the callback, returns,   *)
(* and the engine evaluates in it. Drop the restore from                   *)
(* `ldet_3_6_1__Return` and `integrator_sees_own` fails after the call.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences

\* @spec [LDET.3.6.1]
\* The rounding modes.
CONSTANT ldet_3_6_1__MODES

\* @spec [LDET.3.6.1]
\* The one of them that is round-to-nearest-even.
CONSTANT ldet_3_6_1__RNE

\* @spec [LDET.3.6.1]
\* The engines that may share the thread.
CONSTANT ldet_3_6_1__ENGINES

\* @spec [LDET.3.6.1]
\* How deep calls and callbacks may nest: bounds the state graph.
CONSTANT ldet_3_6_1__DEPTH

\* @spec [LDET.3.6.1]
\* The thread's hardware rounding mode.
VARIABLE ldet_3_6_1__mode

\* @spec [LDET.3.6.1]
\* Control, innermost last: integrator frames carry the mode that code holds;
\* engine frames carry the engine, the mode found on entry, and whether the
\* engine has established its own mode since it last took control.
VARIABLE ldet_3_6_1__stack

\* @spec [LDET.3.6.1]
ldet_3_6_1__vars == << ldet_3_6_1__mode, ldet_3_6_1__stack >>

\* @spec [LDET.3.6.1]
ldet_3_6_1__IntFrame(m) == [kind |-> "int", imode |-> m]

\* @spec [LDET.3.6.1]
ldet_3_6_1__EngFrame(e, m, est) == [kind |-> "eng", eng |-> e, saved |-> m, est |-> est]

\* @spec [LDET.3.6.1]
ldet_3_6_1__top == ldet_3_6_1__stack[Len(ldet_3_6_1__stack)]

\* @spec [LDET.3.6.1]
\* The engines with a call in progress.
ldet_3_6_1__active ==
    { ldet_3_6_1__stack[i].eng : i \in { j \in 1..Len(ldet_3_6_1__stack) :
                                          ldet_3_6_1__stack[j].kind = "eng" } }

\* @spec [LDET.3.6.1]
\* Integrator code holding any mode, with nothing called.
ldet_3_6_1__Init ==
    \E m \in ldet_3_6_1__MODES :
        /\ ldet_3_6_1__mode = m
        /\ ldet_3_6_1__stack = << ldet_3_6_1__IntFrame(m) >>

\* @spec [LDET.3.6.1]
\* Integrator code sets its own mode.
ldet_3_6_1__SetMode(m) ==
    /\ ldet_3_6_1__top.kind = "int"
    /\ ldet_3_6_1__mode' = m
    /\ ldet_3_6_1__stack' =
           [ldet_3_6_1__stack EXCEPT ![Len(ldet_3_6_1__stack)] = ldet_3_6_1__IntFrame(m)]

\* @spec [LDET.3.6.1]
\* Integrator code calls an engine that is not already running ([NLFC.3.3]).
ldet_3_6_1__Call(e) ==
    /\ ldet_3_6_1__top.kind = "int"
    /\ e \notin ldet_3_6_1__active
    /\ Len(ldet_3_6_1__stack) < ldet_3_6_1__DEPTH
    /\ ldet_3_6_1__stack' =
           Append(ldet_3_6_1__stack, ldet_3_6_1__EngFrame(e, ldet_3_6_1__mode, FALSE))
    /\ UNCHANGED ldet_3_6_1__mode

\* @spec [LDET.3.6.1]
\* The engine establishes round-to-nearest-even before it evaluates.
ldet_3_6_1__Establish ==
    /\ ldet_3_6_1__top.kind = "eng"
    /\ ~ldet_3_6_1__top.est
    /\ ldet_3_6_1__mode' = ldet_3_6_1__RNE
    /\ ldet_3_6_1__stack' =
           [ldet_3_6_1__stack EXCEPT ![Len(ldet_3_6_1__stack)].est = TRUE]

\* @spec [LDET.3.6.1]
\* The engine calls back into integrator code, restoring the caller's mode first.
ldet_3_6_1__Callback ==
    /\ ldet_3_6_1__top.kind = "eng"
    /\ ldet_3_6_1__top.est
    /\ Len(ldet_3_6_1__stack) < ldet_3_6_1__DEPTH
    /\ ldet_3_6_1__mode' = ldet_3_6_1__top.saved
    /\ ldet_3_6_1__stack' =
           Append(ldet_3_6_1__stack, ldet_3_6_1__IntFrame(ldet_3_6_1__top.saved))

\* @spec [LDET.3.6.1]
\* A callback returns to the engine, which establishes its own mode again.
ldet_3_6_1__CallbackReturn ==
    /\ ldet_3_6_1__top.kind = "int"
    /\ Len(ldet_3_6_1__stack) > 1
    /\ LET rest == SubSeq(ldet_3_6_1__stack, 1, Len(ldet_3_6_1__stack) - 1)
       IN  /\ ldet_3_6_1__stack' = [rest EXCEPT ![Len(rest)].est = TRUE]
           /\ ldet_3_6_1__mode' = ldet_3_6_1__RNE

\* @spec [LDET.3.6.1]
\* The engine call returns, restoring the mode it found.
ldet_3_6_1__Return ==
    /\ ldet_3_6_1__top.kind = "eng"
    /\ ldet_3_6_1__top.est
    /\ ldet_3_6_1__mode' = ldet_3_6_1__top.saved
    /\ ldet_3_6_1__stack' = SubSeq(ldet_3_6_1__stack, 1, Len(ldet_3_6_1__stack) - 1)

\* @spec [LDET.3.6.1]
ldet_3_6_1__Next ==
    \/ \E m \in ldet_3_6_1__MODES : ldet_3_6_1__SetMode(m)
    \/ \E e \in ldet_3_6_1__ENGINES : ldet_3_6_1__Call(e)
    \/ ldet_3_6_1__Establish
    \/ ldet_3_6_1__Callback
    \/ ldet_3_6_1__CallbackReturn
    \/ ldet_3_6_1__Return

\* @spec [LDET.3.6.1]
ldet_3_6_1__Spec == ldet_3_6_1__Init /\ [][ldet_3_6_1__Next]_ldet_3_6_1__vars

\* @spec [LDET.3.6.1]
ldet_3_6_1__TypeOK ==
    /\ ldet_3_6_1__mode \in ldet_3_6_1__MODES
    /\ Len(ldet_3_6_1__stack) \in 1..ldet_3_6_1__DEPTH
    /\ ldet_3_6_1__stack[1].kind = "int"

\* @spec [LDET.3.6.1]
\* Every engine `Float` operation runs in round-to-nearest-even: whenever the
\* engine has control and has established its mode, that is the mode.
ldet_3_6_1__engine_runs_rne ==
    (ldet_3_6_1__top.kind = "eng" /\ ldet_3_6_1__top.est)
        => ldet_3_6_1__mode = ldet_3_6_1__RNE

\* @spec [LDET.3.6.1]
\* Integrator code only ever sees its own mode.
ldet_3_6_1__integrator_sees_own ==
    ldet_3_6_1__top.kind = "int" => ldet_3_6_1__mode = ldet_3_6_1__top.imode

\* @derives [NDET.1.3]
\* libds does not change the integrator's floating point: at every point where
\* the outermost integrator code has control, its mode is the one it set.
ndet_1_3__outer_untouched ==
    Len(ldet_3_6_1__stack) = 1 => ldet_3_6_1__mode = ldet_3_6_1__stack[1].imode

=============================================================================

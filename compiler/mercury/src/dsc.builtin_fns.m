%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% dsc.builtin_fns -- GENERATED. Do not edit: regenerate it.
%
% [LEXP.17.2]'s builtin functions, one fact per row of the clause's `data` table.
%
% 151 rows; sha256 (first 16) of the rows as JSON: 99cfe6d0053e0826.
%-----------------------------------------------------------------------------%

:- module dsc.builtin_fns.
:- interface.

:- import_module list.

    % [LGRA.9.8.4]'s two purity tiers: a pure call is inlined at every use, a
    % sync-impure one is bound once at the head of the right-hand side.
    %
    %@spec [LEXP.17.2]
:- type lexp_17_2_tier
    --->    tier_pure
    ;       tier_sync_impure.

    % The name, its admitted arities (ascending) and its tier.
    %
    %@spec [LEXP.17.2]
:- pred lexp_17_2_row(string, list(int), lexp_17_2_tier).
    %@spec [LEXP.17.2]
:- mode lexp_17_2_row(in, out, out) is semidet.
    %@spec [LEXP.17.2]
:- mode lexp_17_2_row(out, out, out) is multi.

%-----------------------------------------------------------------------------%
:- implementation.

lexp_17_2_row("abs", [1], tier_pure).
lexp_17_2_row("math.acos", [1], tier_pure).
lexp_17_2_row("math.asin", [1], tier_pure).
lexp_17_2_row("math.atan", [1], tier_pure).
lexp_17_2_row("math.atan2", [2], tier_pure).
lexp_17_2_row("cached", [1], tier_sync_impure).
lexp_17_2_row("math.ceil", [1], tier_pure).
lexp_17_2_row("distance.chebyshev", [4, 6], tier_pure).
lexp_17_2_row("contains", [2], tier_pure).
lexp_17_2_row("math.cos", [1], tier_pure).
lexp_17_2_row("math.cosh", [1], tier_pure).
lexp_17_2_row("distance.cosine", [4, 6], tier_pure).
lexp_17_2_row("count", [1], tier_pure).
lexp_17_2_row("count_distinct", [1], tier_pure).
lexp_17_2_row("count_of", [2], tier_pure).
lexp_17_2_row("calendar.date", [3], tier_pure).
lexp_17_2_row("math.degrees", [1], tier_pure).
lexp_17_2_row("direction", [1], tier_pure).
lexp_17_2_row("distance.euclidean", [4, 6], tier_pure).
lexp_17_2_row("math.exp", [1], tier_pure).
lexp_17_2_row("math.floor", [1], tier_pure).
lexp_17_2_row("math.fma", [3], tier_pure).
lexp_17_2_row("distance.great_circle", [4], tier_pure).
lexp_17_2_row("has", [1], tier_pure).
lexp_17_2_row("distance.hypotenuse", [2, 3], tier_pure).
lexp_17_2_row("len", [1], tier_pure).
lexp_17_2_row("math.ln", [1], tier_pure).
lexp_17_2_row("math.log10", [1], tier_pure).
lexp_17_2_row("math.log2", [1], tier_pure).
lexp_17_2_row("distance.manhattan", [4, 6], tier_pure).
lexp_17_2_row("max", [2], tier_pure).
lexp_17_2_row("mean", [1], tier_pure).
lexp_17_2_row("median", [1], tier_pure).
lexp_17_2_row("min", [2], tier_pure).
lexp_17_2_row("monotonic_ns", [0], tier_sync_impure).
lexp_17_2_row("now", [0], tier_sync_impure).
lexp_17_2_row("p1", [1], tier_pure).
lexp_17_2_row("p2", [1], tier_pure).
lexp_17_2_row("p3", [1], tier_pure).
lexp_17_2_row("p4", [1], tier_pure).
lexp_17_2_row("p5", [1], tier_pure).
lexp_17_2_row("p6", [1], tier_pure).
lexp_17_2_row("p7", [1], tier_pure).
lexp_17_2_row("p8", [1], tier_pure).
lexp_17_2_row("p9", [1], tier_pure).
lexp_17_2_row("p10", [1], tier_pure).
lexp_17_2_row("p11", [1], tier_pure).
lexp_17_2_row("p12", [1], tier_pure).
lexp_17_2_row("p13", [1], tier_pure).
lexp_17_2_row("p14", [1], tier_pure).
lexp_17_2_row("p15", [1], tier_pure).
lexp_17_2_row("p16", [1], tier_pure).
lexp_17_2_row("p17", [1], tier_pure).
lexp_17_2_row("p18", [1], tier_pure).
lexp_17_2_row("p19", [1], tier_pure).
lexp_17_2_row("p20", [1], tier_pure).
lexp_17_2_row("p21", [1], tier_pure).
lexp_17_2_row("p22", [1], tier_pure).
lexp_17_2_row("p23", [1], tier_pure).
lexp_17_2_row("p24", [1], tier_pure).
lexp_17_2_row("p25", [1], tier_pure).
lexp_17_2_row("p26", [1], tier_pure).
lexp_17_2_row("p27", [1], tier_pure).
lexp_17_2_row("p28", [1], tier_pure).
lexp_17_2_row("p29", [1], tier_pure).
lexp_17_2_row("p30", [1], tier_pure).
lexp_17_2_row("p31", [1], tier_pure).
lexp_17_2_row("p32", [1], tier_pure).
lexp_17_2_row("p33", [1], tier_pure).
lexp_17_2_row("p34", [1], tier_pure).
lexp_17_2_row("p35", [1], tier_pure).
lexp_17_2_row("p36", [1], tier_pure).
lexp_17_2_row("p37", [1], tier_pure).
lexp_17_2_row("p38", [1], tier_pure).
lexp_17_2_row("p39", [1], tier_pure).
lexp_17_2_row("p40", [1], tier_pure).
lexp_17_2_row("p41", [1], tier_pure).
lexp_17_2_row("p42", [1], tier_pure).
lexp_17_2_row("p43", [1], tier_pure).
lexp_17_2_row("p44", [1], tier_pure).
lexp_17_2_row("p45", [1], tier_pure).
lexp_17_2_row("p46", [1], tier_pure).
lexp_17_2_row("p47", [1], tier_pure).
lexp_17_2_row("p48", [1], tier_pure).
lexp_17_2_row("p49", [1], tier_pure).
lexp_17_2_row("p50", [1], tier_pure).
lexp_17_2_row("p51", [1], tier_pure).
lexp_17_2_row("p52", [1], tier_pure).
lexp_17_2_row("p53", [1], tier_pure).
lexp_17_2_row("p54", [1], tier_pure).
lexp_17_2_row("p55", [1], tier_pure).
lexp_17_2_row("p56", [1], tier_pure).
lexp_17_2_row("p57", [1], tier_pure).
lexp_17_2_row("p58", [1], tier_pure).
lexp_17_2_row("p59", [1], tier_pure).
lexp_17_2_row("p60", [1], tier_pure).
lexp_17_2_row("p61", [1], tier_pure).
lexp_17_2_row("p62", [1], tier_pure).
lexp_17_2_row("p63", [1], tier_pure).
lexp_17_2_row("p64", [1], tier_pure).
lexp_17_2_row("p65", [1], tier_pure).
lexp_17_2_row("p66", [1], tier_pure).
lexp_17_2_row("p67", [1], tier_pure).
lexp_17_2_row("p68", [1], tier_pure).
lexp_17_2_row("p69", [1], tier_pure).
lexp_17_2_row("p70", [1], tier_pure).
lexp_17_2_row("p71", [1], tier_pure).
lexp_17_2_row("p72", [1], tier_pure).
lexp_17_2_row("p73", [1], tier_pure).
lexp_17_2_row("p74", [1], tier_pure).
lexp_17_2_row("p75", [1], tier_pure).
lexp_17_2_row("p76", [1], tier_pure).
lexp_17_2_row("p77", [1], tier_pure).
lexp_17_2_row("p78", [1], tier_pure).
lexp_17_2_row("p79", [1], tier_pure).
lexp_17_2_row("p80", [1], tier_pure).
lexp_17_2_row("p81", [1], tier_pure).
lexp_17_2_row("p82", [1], tier_pure).
lexp_17_2_row("p83", [1], tier_pure).
lexp_17_2_row("p84", [1], tier_pure).
lexp_17_2_row("p85", [1], tier_pure).
lexp_17_2_row("p86", [1], tier_pure).
lexp_17_2_row("p87", [1], tier_pure).
lexp_17_2_row("p88", [1], tier_pure).
lexp_17_2_row("p89", [1], tier_pure).
lexp_17_2_row("p90", [1], tier_pure).
lexp_17_2_row("p91", [1], tier_pure).
lexp_17_2_row("p92", [1], tier_pure).
lexp_17_2_row("p93", [1], tier_pure).
lexp_17_2_row("p94", [1], tier_pure).
lexp_17_2_row("p95", [1], tier_pure).
lexp_17_2_row("p96", [1], tier_pure).
lexp_17_2_row("p97", [1], tier_pure).
lexp_17_2_row("p98", [1], tier_pure).
lexp_17_2_row("p99", [1], tier_pure).
lexp_17_2_row("math.pow", [2], tier_pure).
lexp_17_2_row("pstdev", [1], tier_pure).
lexp_17_2_row("pvariance", [1], tier_pure).
lexp_17_2_row("math.radians", [1], tier_pure).
lexp_17_2_row("rate", [1], tier_pure).
lexp_17_2_row("round", [1], tier_pure).
lexp_17_2_row("math.sign", [1], tier_pure).
lexp_17_2_row("math.sin", [1], tier_pure).
lexp_17_2_row("math.sinh", [1], tier_pure).
lexp_17_2_row("math.sqrt", [1], tier_pure).
lexp_17_2_row("stdev", [1], tier_pure).
lexp_17_2_row("math.tan", [1], tier_pure).
lexp_17_2_row("math.tanh", [1], tier_pure).
lexp_17_2_row("calendar.time", [3, 6, 7], tier_pure).
lexp_17_2_row("math.trunc", [1], tier_pure).
lexp_17_2_row("variance", [1], tier_pure).

%-----------------------------------------------------------------------------%
:- end_module dsc.builtin_fns.
%-----------------------------------------------------------------------------%

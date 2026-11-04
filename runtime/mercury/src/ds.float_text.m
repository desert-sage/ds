% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.float_text -- Float text in both directions, bound from libds's `float_fmt`
% (`runtime/src/libds/float_fmt.h`), so the runtime, the compiler and libds share
% one implementation ([LDET.3.3a.8]). Nothing here computes a digit.
%
% A sanctioned exception to the promise ledger: a conversion is a function of its
% input alone and keeps no state between calls.
%-----------------------------------------------------------------------------%

:- module ds.float_text.
:- interface.

    % `ds_fmt_float`: the canonical text [LDET.3.2.7] -- the shortest digits
    % that round-trip, `.0` kept on a whole value, fixed notation for a decimal
    % exponent in [-4, 15] and scientific otherwise, `-0.0` preserved, `inf` /
    % `-inf`, and `nan` for every NaN, whatever its sign ([LCST.4.5.6]).
    %
:- func canonical(float) = string.

    % `ds_fmt_float_fixed`: exactly `Prec` decimals, the binary value correctly
    % rounded, ties to even, no exponent, and no decimal point when `Prec` is 0.
    % A negative `Prec` is taken as 0.
    %
:- func fixed(float, int) = string.

    % `ds_parse_float_json`: the whole string as one RFC 8259 number, correctly
    % rounded, ties to even, for any number of digits. Past the largest finite
    % double it reads as ±inf, below the smallest subnormal as ±0. Fails on
    % anything that is not exactly one JSON number.
    %
:- pred parse_json(string::in, float::out) is semidet.

    % `ds_parse_float_text`: `String::Float?` [LCST.4.5.8] -- an optional sign
    % and an INT_LIT or FLOAT_LIT as source spells it, or `inf`, correctly
    % rounded. Fails on anything else and on a finite spelling that rounds to
    % an infinity.
    %
:- pred parse_text(string::in, float::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.

:- pragma foreign_decl("C", "
#include <stdlib.h>
#include <string.h>
#include \"float_fmt.h\"
").

canonical(F) = Text :-
    foreign_canonical(F, Text).

fixed(F, Prec) = Text :-
    foreign_fixed(F, int.max(Prec, 0), Text).

parse_json(Text, F) :-
    foreign_parse(Text, 0, F).

parse_text(Text, F) :-
    foreign_parse(Text, 1, F).

:- pred foreign_canonical(float::in, string::out) is det.

:- pragma foreign_proc("C",
    foreign_canonical(F::in, Text::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    /* The longest canonical text is 24 bytes (float_fmt.h). */
    char buf[32];
    ds_fmt_float(buf, sizeof buf, F);
    MR_make_aligned_string_copy(Text, buf);
").

:- pred foreign_fixed(float::in, int::in, string::out) is det.

:- pragma foreign_proc("C",
    foreign_fixed(F::in, Prec::in, Text::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    /* A finite value can need ~310 + Prec bytes. */
    int need = ds_fmt_float_fixed(NULL, 0, F, (unsigned) Prec);
    char *buf = (char *) malloc((size_t) need + 1u);
    if (buf == NULL) {
        MR_fatal_error(\"ds.float_text: out of memory writing a Float\");
    }
    ds_fmt_float_fixed(buf, (size_t) need + 1u, F, (unsigned) Prec);
    MR_make_aligned_string_copy(Text, buf);
    free(buf);
").

    % Mode 0 is `ds_parse_float_json`, 1 is `ds_parse_float_text`.
    %
:- pred foreign_parse(string::in, int::in, float::out) is semidet.

:- pragma foreign_proc("C",
    foreign_parse(Text::in, Mode::in, F::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    double v = 0.0;
    size_t n = strlen(Text);
    int rc = (Mode == 0) ? ds_parse_float_json(Text, n, &v)
                         : ds_parse_float_text(Text, n, &v);
    F = v;
    SUCCESS_INDICATOR = (rc == 0);
").

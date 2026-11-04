% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.re2 -- RE2, DS's regex language ([LREG.8.1], [LREG.8.4]), for the runtime and
% the compiler, through `runtime/src/libds/ds_re2.h`.
%
% A sanctioned foreign module. Each `promise_pure` is true: a compile is a function
% of the pattern and flags, a match of those and the text, and neither retains
% anything.
%-----------------------------------------------------------------------------%

:- module ds.re2.
:- interface.

:- import_module bool.
:- import_module list.
:- import_module maybe.

    % [LREG.5.2]'s three flags.
    %
:- type re2_flags
    --->    re2_flags(
                rf_case_insensitive :: bool,    % `i`
                rf_multiline        :: bool,    % `m`
                rf_dot_all          :: bool     % `s`
            ).

    % What RE2 says about a pattern: every capturing group left to right, each
    % with its name when it has one ([LREG.3.1]), or RE2's own error text.
    %
:- type re2_pattern
    --->    re2_valid(list(maybe(string)))
    ;       re2_invalid(string).

:- func re2_compile(string, re2_flags) = re2_pattern.

    % The `flags` argument of `FN_REGEX_MATCH`: each of `i`, `m`, `s` present or not,
    % anything else ignored ([LREG.5.3], [LREG.5.4] refuse the rest at compile time).
    %
:- func re2_flags_of_letters(string) = re2_flags.

    % A partial match -- "matches somewhere in", the meaning `~` has
    % ([LREG.1.2]). Fails on a pattern RE2 does not accept.
    %
:- pred re2_matches(string::in, re2_flags::in, string::in) is semidet.

    % One capturing group of one partial match ([LREG.4.1]), `group` 1-based. A group
    % that did not participate is `re2_captured("")` ([LREG.4.4]).
    %
:- type re2_capture
    --->    re2_captured(string)
    ;       re2_no_match
    ;       re2_no_such_group   % below 1, above 64, or past the group count
    ;       re2_rejected.       % RE2 does not accept the pattern

:- func re2_capture(string, re2_flags, string, int) = re2_capture.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module char.
:- import_module int.
:- import_module string.

:- pragma foreign_decl("C", "
#include <stdlib.h>
#include <string.h>
#include \"ds_re2.h\"
").

re2_compile(Pattern, Flags) = Result :-
    foreign_compile(Pattern, flag_mask(Flags), Ok, Count, Names, Error),
    ( if Ok = 1 then
        Result = re2_valid(group_names(Count, Names))
    else
        Result = re2_invalid(Error)
    ).

re2_matches(Pattern, Flags, Text) :-
    foreign_matches(Pattern, flag_mask(Flags), Text).

re2_capture(Pattern, Flags, Text, Group) = Result :-
    foreign_capture(Pattern, flag_mask(Flags), Text, Group, Status, Piece),
    ( if Status = 3 then
        Result = re2_captured(Piece)
    else if Status = 2 then
        Result = re2_no_match
    else if Status = 1 then
        Result = re2_no_such_group
    else
        Result = re2_rejected
    ).

re2_flags_of_letters(Letters) =
    re2_flags(letter(Letters, 'i'), letter(Letters, 'm'), letter(Letters, 's')).

:- func letter(string, char) = bool.

letter(Letters, C) = ( if string.contains_char(Letters, C) then yes else no ).

    % `ds_re2.h`'s `DS_RE2_ICASE` / `DS_RE2_MULTILINE` / `DS_RE2_DOTALL`.
    %
:- func flag_mask(re2_flags) = int.

flag_mask(re2_flags(I, M, S)) = bit(I, 1) \/ bit(M, 2) \/ bit(S, 4).

:- func bit(bool, int) = int.

bit(yes, Bit) = Bit.
bit(no, _) = 0.

    % The C side writes one line per group, the name or nothing.
    %
:- func group_names(int, string) = list(maybe(string)).

group_names(Count, Joined) =
    list.map(named, list.take_upto(Count,
        string.split_at_char('\n', Joined))).

:- func named(string) = maybe(string).

named(Name) = ( if Name = "" then no else yes(Name) ).

:- pred foreign_compile(string::in, int::in, int::out, int::out, string::out,
                        string::out) is det.

:- pragma foreign_proc("C",
    foreign_compile(Pattern::in, Mask::in, Ok::out, Count::out, Names::out,
                    Error::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    char err[512];
    ds_re2_t *re = ds_re2_compile(Pattern, (unsigned) Mask, err, sizeof err);
    /* IALC.3.6: out of memory is not RE2 refusing the pattern, which is what
       `re2_invalid` reports to an author. It ends the process, as the malloc
       failure below does. */
    if (re == NULL && strcmp(err, DS_RE2_ERR_OOM) == 0) {
        MR_fatal_error(\"ds.re2: out of memory compiling a regex\");
    }
    if (re == NULL) {
        Ok = 0;
        Count = 0;
        MR_make_aligned_string(Names, \"\");
        MR_make_aligned_string_copy(Error, err);
    } else {
        int n = ds_re2_group_count(re);
        size_t cap = 1;
        size_t at = 0;
        char *buf;
        int i;
        /* An unnamed group is NULL, written as the empty line `named` reads
           as `no`; RE2 names no group with the empty string. */
        for (i = 1; i <= n; i++) {
            const char *nm = ds_re2_group_name(re, i);
            cap += (nm == NULL ? 0 : strlen(nm)) + 1;
        }
        buf = (char *) malloc(cap);
        if (buf == NULL) {
            ds_re2_free(re);
            MR_fatal_error(\"ds.re2: out of memory reading group names\");
        }
        for (i = 1; i <= n; i++) {
            const char *nm = ds_re2_group_name(re, i);
            if (nm != NULL) {
                size_t len = strlen(nm);
                memcpy(buf + at, nm, len);
                at += len;
            }
            buf[at++] = '\\n';
        }
        buf[at] = '\\0';
        MR_make_aligned_string_copy(Names, buf);
        free(buf);
        Ok = 1;
        Count = n;
        MR_make_aligned_string(Error, \"\");
        ds_re2_free(re);
    }
").

:- pred foreign_matches(string::in, int::in, string::in) is semidet.

:- pragma foreign_proc("C",
    foreign_matches(Pattern::in, Mask::in, Text::in),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    /* IALC.3.6: an exhausted RE2 is not \"no match\". It ends the process, as an
       exhausted heap does here. */
    char err[64];
    bool oom = false;
    ds_re2_t *re;
    err[0] = '\\0';
    re = ds_re2_compile(Pattern, (unsigned) Mask, err, sizeof err);
    if (re == NULL && strcmp(err, DS_RE2_ERR_OOM) == 0) {
        MR_fatal_error(\"ds.re2: out of memory compiling a regex\");
    }
    SUCCESS_INDICATOR =
        (re != NULL && ds_re2_match_n(re, Text, strlen(Text), &oom));
    ds_re2_free(re);
    if (oom) {
        MR_fatal_error(\"ds.re2: out of memory matching a regex\");
    }
").

    % Status 0 rejected, 1 no such group, 2 no match, 3 captured. The group bound is
    % checked before the match: RE2 fills a slot past the count with the same NULL a
    % non-participating group gets.
    %
:- pred foreign_capture(string::in, int::in, string::in, int::in, int::out,
                        string::out) is det.

:- pragma foreign_proc("C",
    foreign_capture(Pattern::in, Mask::in, Text::in, Group::in, Status::out,
                    Piece::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    /* IALC.3.6, as in foreign_matches: an exhausted RE2 ends the process. */
    char err[64];
    bool oom = false;
    ds_re2_t *re;
    err[0] = '\\0';
    re = ds_re2_compile(Pattern, (unsigned) Mask, err, sizeof err);
    if (re == NULL && strcmp(err, DS_RE2_ERR_OOM) == 0) {
        MR_fatal_error(\"ds.re2: out of memory compiling a regex\");
    }
    if (re == NULL) {
        Status = 0;
        MR_make_aligned_string(Piece, \"\");
    } else if (Group < 1 || Group > 64 || Group > ds_re2_group_count(re)) {
        Status = 1;
        MR_make_aligned_string(Piece, \"\");
        ds_re2_free(re);
    } else {
        const char *ptr[64];
        size_t len[64];
        if (!ds_re2_capture(re, Text, ptr, len, (int) Group, &oom)) {
            if (oom) {
                ds_re2_free(re);
                MR_fatal_error(\"ds.re2: out of memory capturing a regex\");
            }
            Status = 2;
            MR_make_aligned_string(Piece, \"\");
        } else {
            /* The piece is a view into Text and is not NUL-terminated. */
            const char *p = ptr[Group - 1];
            size_t n = (p == NULL) ? 0 : len[Group - 1];
            char *buf = (char *) malloc(n + 1);
            if (buf == NULL) {
                ds_re2_free(re);
                MR_fatal_error(\"ds.re2: out of memory copying a capture\");
            }
            if (n > 0) {
                memcpy(buf, p, n);
            }
            buf[n] = '\\0';
            MR_make_aligned_string_copy(Piece, buf);
            free(buf);
            Status = 3;
        }
        ds_re2_free(re);
    }
").

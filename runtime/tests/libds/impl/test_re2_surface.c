/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The regex surface libds's RE2 executes, construct by construct: what
 * [LREG.8.3] admits compiles, its residue (`\u{HHHH}`, `\Z`) and what
 * [LREG.8.4] rejects are refused by RE2 itself. A row pins RE2's behaviour, so
 * an RE2 that moves fails here.
 */
#include <stdio.h>
#include <stddef.h>

#include "ds_re2.h"

struct surface {
    const char *clause;   /* the list that names it, or "-" for neither */
    const char *label;
    const char *pat;
    int         want_ok;  /* 1 = RE2 must compile it, 0 = RE2 must refuse it */
};

static const struct surface SURFACE[] = {
    /* [LREG.8.3] — "supported by RE2 and admitted in v1". */
    {"8.3", "class literal",          "[abc]",        1},
    {"8.3", "class negated",          "[^abc]",       1},
    {"8.3", "class range",            "[a-z]",        1},
    {"8.3", "named class \\d",        "\\d",          1},
    {"8.3", "named class \\w",        "\\w",          1},
    {"8.3", "named class \\s",        "\\s",          1},
    {"8.3", "named class \\D",        "\\D",          1},
    {"8.3", "named class \\W",        "\\W",          1},
    {"8.3", "named class \\S",        "\\S",          1},
    {"8.3", "named class posix",      "[[:alpha:]]",  1},
    {"8.3", "named class \\pL",       "\\pL",         1},
    {"8.3", "named class \\p{Greek}", "\\p{Greek}",   1},
    {"8.3", "quant *",                "a*",           1},
    {"8.3", "quant +",                "a+",           1},
    {"8.3", "quant ?",                "a?",           1},
    {"8.3", "quant {n}",              "a{2}",         1},
    {"8.3", "quant {n,m}",            "a{2,3}",       1},
    {"8.3", "quant *? lazy",          "a*?",          1},
    {"8.3", "quant +? lazy",          "a+?",          1},
    {"8.3", "quant ?? lazy",          "a??",          1},
    {"8.3", "quant {n}? lazy",        "a{2}?",        1},
    {"8.3", "quant {n,m}? lazy",      "a{2,3}?",      1},
    {"8.3", "alternation",            "a|b",          1},
    {"8.3", "group capturing",        "(a)",          1},
    {"8.3", "group named (?<n>)",     "(?<n>a)",      1},
    {"8.3", "group named (?P<n>)",    "(?P<n>a)",     1},
    {"8.3", "group non-capturing",    "(?:a)",        1},
    {"8.3", "anchor ^",               "^a",           1},
    {"8.3", "anchor $",               "a$",           1},
    {"8.3", "anchor \\b",             "\\ba",         1},
    {"8.3", "anchor \\B",             "\\Ba",         1},
    {"8.3", "escape \\n",             "\\n",          1},
    {"8.3", "escape \\t",             "\\t",          1},
    {"8.3", "escape \\r",             "\\r",          1},
    {"8.3", "escape \\0",             "\\0",          1},
    {"8.3", "escape \\xHH",           "\\x41",        1},
    {"8.3", "escape \\x{...}",        "\\x{1F600}",   1},
    /* RE2 has no `\u` escape ([LREG.8.3]). */
    {"8.3", "escape \\u{HHHH}",       "\\u{0041}",    0},
    {"8.3", "escape \\uHHHH",         "\\u0041",      0},
    {"8.3", "escape \\.",             "\\.",          1},
    {"8.3", "escape \\*",             "\\*",          1},
    {"8.3", "escape backslash",       "\\\\",         1},
    /* [LREG.8.4]: each is refused by RE2 itself. */
    {"8.4", "backref \\1",            "(a)\\1",       0},
    {"8.4", "backref \\2",            "(a)(b)\\2",    0},
    {"8.4", "backref \\k<n>",         "(?<n>a)\\k<n>", 0},
    {"8.4", "lookahead (?=)",         "a(?=b)",       0},
    {"8.4", "lookahead (?!)",         "a(?!b)",       0},
    {"8.4", "lookbehind (?<=)",       "(?<=a)b",      0},
    {"8.4", "lookbehind (?<!)",       "(?<!a)b",      0},
    {"8.4", "possessive *+",          "a*+",          0},
    {"8.4", "possessive ++",          "a++",          0},
    {"8.4", "possessive ?+",          "a?+",          0},
    {"8.4", "possessive {n,m}+",      "a{2,3}+",      0},
    {"8.4", "atomic group (?>)",      "(?>a)",        0},
    {"-",   "dot",                    "a.b",          1},
    {"-",   "class holding * then +", "[*+]",         1},
    {"-",   "class holding ? then +", "[?+]",         1},
    {"-",   "class holding } then +", "[}+]",         1},
    {"-",   "class holding \\1",      "[\\1]",        0},
    {"-",   "inline flag (?i)",       "(?i)a",        1},
    {"-",   "inline flag (?s)",       "(?s)a.b",      1},
    {"-",   "inline flag (?m)",       "(?m)^a",       1},
    {"-",   "inline flag (?U)",       "(?U)a+",       1},
    {"-",   "inline flag group (?i:)", "(?i:a)",      1},
    {"-",   "anchor \\A",             "\\Aa",         1},
    {"-",   "anchor \\z",             "a\\z",         1},
    {"-",   "anchor \\Z",             "a\\Z",         0},
    {"-",   "nested repeat",          "(a*)*",        1},
    {"-",   "named backref (?P=n)",   "(?P<n>a)(?P=n)", 0},
};

int main(void)
{
    size_t i;
    size_t n = sizeof SURFACE / sizeof SURFACE[0];
    int fails = 0;

    for (i = 0; i < n; i++) {
        char err[256];
        ds_re2_t *re;
        err[0] = '\0';
        re = ds_re2_compile(SURFACE[i].pat, 0u, err, sizeof err);
        if (SURFACE[i].want_ok && re == NULL) {
            fprintf(stderr,
                    "FAIL: [%s] %s <%s> — this RE2 refuses a construct the "
                    "pinned one compiles: %s\n",
                    SURFACE[i].clause, SURFACE[i].label, SURFACE[i].pat, err);
            fails++;
        } else if (!SURFACE[i].want_ok && re != NULL) {
            fprintf(stderr,
                    "FAIL: [%s] %s <%s> — this RE2 compiles a construct the "
                    "pinned one refuses\n",
                    SURFACE[i].clause, SURFACE[i].label, SURFACE[i].pat);
            fails++;
        }
        if (re)
            ds_re2_free(re);
    }

    if (fails) {
        fprintf(stderr,
                "test_re2_surface: %d construct(s) disagree with the pinned "
                "surface\n", fails);
        return 1;
    }
    printf("test_re2_surface: OK (%zu constructs)\n", n);
    return 0;
}

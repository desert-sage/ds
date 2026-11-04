// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// float_parse.cc — text -> Float for libds, through fast_float ([LDET.3.2.8]).
//
// In a subdirectory because libds.build compiles top-level `*.cc` only when RE2 is
// linked, and every build needs this unit. It references no C++ runtime.
//
// A decimal spelling is validated here, then handed to fast_float rewritten as the
// JSON number `0.<digits>e<exp>` in a fixed buffer: at most KEEP significant digits,
// then one `1` when a dropped digit was non-zero. That is exact for rounding: fast_float
// decides on at most 768 digits and a "something non-zero follows" flag.

#include "../float_fmt.h"

#include <cstdint>
#include <cstring>
#include <limits>

#include "fast_float/fast_float.h"

namespace {

int parse_json(const char *s, size_t n, double *out)
{
    double v = 0.0;
    fast_float::from_chars_result r =
        fast_float::from_chars(s, s + n, v, fast_float::chars_format::json);
    if (r.ptr != s + n) return -1;
    // result_out_of_range: fast_float has already written ±Inf (overflow) or
    // ±0 (underflow), which is the value [LDET.3.2.8] gives such a number.
    if (r.ec != std::errc() && r.ec != std::errc::result_out_of_range) return -1;
    *out = v;
    return 0;
}

// ---- DS's numeric literal grammar ([LLEX.11.1], [LLEX.11.2]) ------------

int digit_of(char c, unsigned base)
{
    int v;
    if (c >= '0' && c <= '9')      v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    else return -1;
    return v < static_cast<int>(base) ? v : -1;
}

// `DIGIT ('_'? DIGIT)*` in `base`, maximal: its end, or nullptr when there is none or a
// `_` is not followed by a digit of `base`.
const char *digit_run(const char *p, const char *end, unsigned base)
{
    if (p == end || digit_of(*p, base) < 0) return nullptr;
    const char *q = p + 1;
    while (q < end) {
        if (digit_of(*q, base) >= 0) { q++; continue; }
        if (*q != '_') break;
        if (q + 1 == end || digit_of(q[1], base) < 0) return nullptr;
        q += 2;
    }
    return q;
}

// The base a prefix names, or 0. Lowercase only ([LLEX.11.1]).
unsigned prefix_base(const char *p, const char *end)
{
    if (end - p < 2 || p[0] != '0') return 0;
    switch (p[1]) {
    case 'x': return 16;
    case 'b': return 2;
    case 'o': return 8;
    default:  return 0;
    }
}

// Advances `p`; true for `-`.
bool take_sign(const char *&p, const char *end)
{
    if (p < end && (*p == '+' || *p == '-')) return *p++ == '-';
    return false;
}

// A `0x` / `0b` / `0o` integer of any length, ties to even. -1 when it rounds to an
// infinity ([LCST.4.5.8]). The first 64 bits are kept and later ones only move the
// exponent and the sticky flag. Built by doubling from an exact integer below 2^53,
// which no rounding mode can disturb.
int radix2_to_double(const char *digits, const char *end, unsigned base,
                     double *out)
{
    const unsigned width = base == 16 ? 4u : base == 8 ? 3u : 1u;
    std::uint64_t m = 0;
    unsigned mbits = 0;
    long long exp2 = 0;
    bool sticky = false;
    for (const char *p = digits; p < end; p++) {
        if (*p == '_') continue;
        unsigned d = static_cast<unsigned>(digit_of(*p, base));
        for (int b = static_cast<int>(width) - 1; b >= 0; b--) {
            unsigned bit = (d >> b) & 1u;
            if (mbits == 0 && bit == 0) continue;
            if (mbits < 64) { m = (m << 1) | bit; mbits++; }
            else            { exp2++; sticky = sticky || bit; }
        }
    }
    if (mbits == 0) { *out = 0.0; return 0; }
    if (mbits > 53) {
        unsigned drop = mbits - 53;
        std::uint64_t rem  = m & ((std::uint64_t{1} << drop) - 1);
        std::uint64_t half = std::uint64_t{1} << (drop - 1);
        m >>= drop;
        exp2 += drop;
        if (rem > half || (rem == half && (sticky || (m & 1)))) {
            m++;
            if (m == (std::uint64_t{1} << 53)) { m >>= 1; exp2++; }
        }
    }
    double v = static_cast<double>(m);
    for (long long i = 0; i < exp2; i++) {
        v *= 2.0;
        if (v == std::numeric_limits<double>::infinity()) return -1;
    }
    *out = v;
    return 0;
}

struct Sig {
    static const unsigned KEEP = 800;
    char d[KEEP + 1];
    unsigned n = 0;         // digits stored
    long long seen = 0;     // significant digits seen, stored or not
    bool tail = false;      // a non-zero digit was dropped past KEEP
    void add(char c)
    {
        if (seen == 0 && c == '0') return;
        seen++;
        if (n < KEEP) d[n++] = c;
        else if (c != '0') tail = true;
    }
};

// `DEC_LIT ('.' DEC_LIT)? (('e'|'E') [+-]? DEC_LIT)?`, exactly the bytes at `p` .. `end`.
// -1 for anything else, or when the value rounds to an infinity.
int decimal_to_double(const char *p, const char *end, bool neg, double *out)
{
    const char *ie = digit_run(p, end, 10);
    if (ie == nullptr) return -1;
    const char *fs = nullptr, *fe = nullptr;
    const char *q = ie;
    if (q < end && *q == '.') {
        fs = q + 1;
        fe = digit_run(fs, end, 10);
        if (fe == nullptr) return -1;
        q = fe;
    }
    long long exp10 = 0;
    if (q < end && (*q == 'e' || *q == 'E')) {
        const char *r = q + 1;
        bool eneg = take_sign(r, end);
        const char *ee = digit_run(r, end, 10);
        if (ee == nullptr) return -1;
        for (const char *t = r; t < ee; t++) {
            if (*t == '_') continue;
            if (exp10 < 100000000) exp10 = exp10 * 10 + (*t - '0');  // saturate
        }
        if (eneg) exp10 = -exp10;
        q = ee;
    }
    if (q != end) return -1;

    Sig sig;
    long long int_digits = 0;
    for (const char *t = p; t < ie; t++) {
        if (*t == '_') continue;
        long long before = sig.seen;
        sig.add(*t);
        if (sig.seen != before) int_digits++;
    }
    for (const char *t = fs; fs != nullptr && t < fe; t++) {
        if (*t == '_') continue;
        if (sig.seen == 0 && *t == '0') { int_digits--; continue; }
        sig.add(*t);
    }
    if (sig.seen == 0) { *out = neg ? -0.0 : 0.0; return 0; }
    // value = 0.<digits> * 10^(int_digits + exp10)
    char buf[Sig::KEEP + 64];
    char *w = buf;
    if (neg) *w++ = '-';
    *w++ = '0'; *w++ = '.';
    unsigned keep = sig.n;
    while (keep > 1 && sig.d[keep - 1] == '0' && !sig.tail) keep--;
    std::memcpy(w, sig.d, keep); w += keep;
    if (sig.tail) *w++ = '1';
    long long e = int_digits + exp10;
    if (e > 100000000) e = 100000000;
    if (e < -100000000) e = -100000000;
    // By hand: libds links no printf family.
    *w++ = 'e';
    if (e < 0) { *w++ = '-'; e = -e; }
    char rev[12];
    int k = 0;
    do { rev[k++] = static_cast<char>('0' + e % 10); e /= 10; } while (e > 0);
    while (k > 0) *w++ = rev[--k];
    double v;
    if (parse_json(buf, static_cast<size_t>(w - buf), &v) != 0) return -1;
    if (v == std::numeric_limits<double>::infinity() ||
        v == -std::numeric_limits<double>::infinity()) return -1;
    *out = v;
    return 0;
}

} // namespace

extern "C" int ds_parse_float_json(const char *s, size_t n, double *out)
{
    return parse_json(s, n, out);
}

extern "C" int ds_parse_float_text(const char *s, size_t n, double *out)
{
    const char *p = s, *end = s + n;
    bool neg = take_sign(p, end);
    if (end - p == 3 && std::memcmp(p, "inf", 3) == 0) {
        const double inf = std::numeric_limits<double>::infinity();
        *out = neg ? -inf : inf;
        return 0;
    }
    if (unsigned base = prefix_base(p, end)) {
        if (digit_run(p + 2, end, base) != end) return -1;
        double v;
        if (radix2_to_double(p + 2, end, base, &v) != 0) return -1;
        *out = neg ? -v : v;
        return 0;
    }
    return decimal_to_double(p, end, neg, out);
}

extern "C" int ds_parse_int_text(const char *s, size_t n, int64_t *out)
{
    const char *p = s, *end = s + n;
    bool neg = take_sign(p, end);
    unsigned base = prefix_base(p, end);
    const char *digits = base != 0 ? p + 2 : p;
    if (base == 0) base = 10;
    if (digit_run(digits, end, base) != end) return -1;
    std::uint64_t mag = 0;
    for (const char *t = digits; t < end; t++) {
        if (*t == '_') continue;
        std::uint64_t d = static_cast<std::uint64_t>(digit_of(*t, base));
        if (mag > (UINT64_MAX - d) / base) return -1;
        mag = mag * base + d;
    }
    const std::uint64_t lim = std::uint64_t{1} << 63;
    if (neg) {
        if (mag > lim) return -1;
        *out = mag == lim ? INT64_MIN : -static_cast<int64_t>(mag);
    } else {
        if (mag >= lim) return -1;
        *out = static_cast<int64_t>(mag);
    }
    return 0;
}

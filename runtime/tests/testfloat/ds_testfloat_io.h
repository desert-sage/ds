/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_testfloat_io.h -- what [NDET.1.4]'s two subjects share:
 * ds_subject.c (part 1, the operations libds compiles inline) and
 * ds_helpers.c (part 2, the helpers libds's archive calls). One statement of
 * each, so the two cannot part:
 *
 *   - the operand and result text, as testfloat_gen writes it and
 *     testfloat_ver reads it: fixed-width upper-case hex, one case a line;
 *   - SoftFloat's exception-flag bits, from <fenv.h>'s;
 *   - the signalling-NaN exclusion, while Claim A stands, judged on bits
 *     before any floating-point operation. ds_subject.c's header says what
 *     is left out and why; the driver counts it.
 *
 * Static functions in a header, so each subject is still one translation
 * unit compiled with libds's flags.
 */
#ifndef DS_TESTFLOAT_IO_H
#define DS_TESTFLOAT_IO_H

#include <fenv.h>
#include <stdint.h>
#include <string.h>

/* C11 7.6p6: an exception macro is defined iff the target supports that
   exception. wasm32 supports none and defines none; as libds's
   core_math_fenv.h does, each absent one is 0, so the subjects compile there
   and report no flag, which is what `--flags-from-input` is for. */
#ifndef FE_INEXACT
#define FE_INEXACT 0
#endif
#ifndef FE_UNDERFLOW
#define FE_UNDERFLOW 0
#endif
#ifndef FE_OVERFLOW
#define FE_OVERFLOW 0
#endif
#ifndef FE_DIVBYZERO
#define FE_DIVBYZERO 0
#endif
#ifndef FE_INVALID
#define FE_INVALID 0
#endif

static double dbl(uint64_t b)
{
    double d;
    memcpy(&d, &b, sizeof d);
    return d;
}

static uint64_t bits(double d)
{
    uint64_t b;
    memcpy(&b, &d, sizeof b);
    return b;
}

static int is_signalling_nan(uint64_t b)
{
    return (b & UINT64_C(0x7FF0000000000000)) == UINT64_C(0x7FF0000000000000)
        && (b & UINT64_C(0x000FFFFFFFFFFFFF)) != 0
        && (b & UINT64_C(0x0008000000000000)) == 0;
}

static int hex_digit(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/* Exactly `width` hex digits at *p, then `sep`, into hi:lo (a width over 16
   fills hi). Advances *p past both; 0 on anything else. */
static int read_hex128(const char **p, int width, char sep, uint64_t *hi, uint64_t *lo)
{
    uint64_t h = 0, l = 0;
    for (int i = 0; i < width; i++) {
        int d = hex_digit((unsigned char) (*p)[i]);
        if (d < 0) return 0;
        h = h << 4 | l >> 60;
        l = l << 4 | (uint64_t) d;
    }
    if ((*p)[width] != sep) return 0;
    *p += width + 1;
    *hi = h;
    *lo = l;
    return 1;
}

static int read_hex(const char **p, int width, char sep, uint64_t *out)
{
    uint64_t hi;
    return read_hex128(p, width, sep, &hi, out);
}

static char *write_hex128(char *q, uint64_t hi, uint64_t lo, int width)
{
    static const char digits[] = "0123456789ABCDEF";
    for (int i = width - 1; i >= 0; i--) {
        q[i] = digits[lo & 0xF];
        lo = lo >> 4 | hi << 60;
        hi >>= 4;
    }
    return q + width;
}

static char *write_hex(char *q, uint64_t v, int width)
{
    return write_hex128(q, 0, v, width);
}

/* RESULTS ONLY (`--flags-from-input`), for a row with no exception flags:
   wasm32, whose engines raise none. The input is
   testfloat_gen's function form: after the operands, SoftFloat's result and
   flags. The subject skips that result unread and reports those flags as its
   own, so testfloat_ver judges the value alone, by its own rules; nothing in
   the subject compares. Reads ` <result> <flags>\n` after the last operand
   into *flags; 0 on anything else. */
static int read_expected_flags(const char **p, int result_width, uint64_t *flags)
{
    uint64_t hi, lo;
    return read_hex128(p, result_width, ' ', &hi, &lo) && read_hex(p, 2, '\n', flags);
}

/* SoftFloat's flag bits, which testfloat_ver reads (its documentation, "Input
   Format"). */
static uint64_t softfloat_flags(int raised)
{
    return ((raised & FE_INEXACT)   ? 0x01u : 0)
         | ((raised & FE_UNDERFLOW) ? 0x02u : 0)
         | ((raised & FE_OVERFLOW)  ? 0x04u : 0)
         | ((raised & FE_DIVBYZERO) ? 0x08u : 0)
         | ((raised & FE_INVALID)   ? 0x10u : 0);
}

#define ALL_EXCEPTIONS (FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)

/* A subject's exit status when its output could not be written: its reader,
   testfloat_ver, stopped (it stops after its first 20 errors). Where a write
   to a closed pipe kills the writer this is SIGPIPE instead; under node it is
   an error. The driver's WRITE_ERROR says the same number. */
#define DS_TESTFLOAT_WRITE_ERROR 3

#endif /* DS_TESTFLOAT_IO_H */

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The negative fixture a test halts an engine with: an artefact whose Slot
 * atom declares a slot's kind wrongly.
 *
 * No DS program reaches an EngineError, since every language route is a
 * ComputationError, so a test that needs one compiles a program doing
 * arithmetic on an Int slot named `lied`, then edits the artefact so that
 * slot's Slot atom declares String (proto/slot.proto: `slot_name = "lied"`,
 * field 2, then `kind`, field 3, SLOT_KIND_INT 1 -> SLOT_KIND_STRING 3), and
 * recomputes its `dsc_sha256` as the compiler does ([RDSC.3.6]). The negative
 * fixture is built on every run, from the program just compiled. The engine
 * then holds a String where the compiled expression reads an Int, a present
 * value of the wrong type that no Json taint explains:
 * ENGINE_FAULT_ARTEFACT_LIED, an EngineError. One byte inside one atom, so no
 * length prefix moves.
 *
 * Written against libds.h alone, as pyds's test_binding_contracts.py and
 * @ds-lang/ds's engine.test.mjs make the same edit in their languages. Used by
 * test_ncbk_2_9__latching_call_returns_engine_halted,
 * test_ncbk_2_9__a_read_after_the_halt_is_refused and
 * test_lerr_1_4_7__engine_error_stops_the_pump. `reseal` alone, after an edit
 * of its own, by test_rdsc_4a_9_6__a_conversion_bind_index_past_0.
 *
 * Every function is `static inline`, so a test that uses one is not warned of
 * the others.
 */
#ifndef DS_SPEC_TAMPER_H
#define DS_SPEC_TAMPER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* ---- SHA-256, the header's dsc_sha256 ------------------------------------ */

static const uint32_t K256[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static inline uint32_t ror32(uint32_t x, unsigned n)
{
    return (x >> n) | (x << (32 - n));
}

static inline void sha256_block(uint32_t h[8], const uint8_t *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t) p[4 * i] << 24 | (uint32_t) p[4 * i + 1] << 16
             | (uint32_t) p[4 * i + 2] << 8 | (uint32_t) p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
    uint32_t e = h[4], f = h[5], g = h[6], k = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = k + (ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25))
                    + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22))
                    + ((a & b) ^ (a & c) ^ (b & c));
        k = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += k;
}

/* FIPS 180-4 SHA-256 of buf[0..n), into out[32]. */
static inline void sha256(const uint8_t *buf, size_t n, uint8_t out[32])
{
    uint32_t h[8] = { 0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                      0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u };
    size_t i = 0;
    for (; i + 64 <= n; i += 64) sha256_block(h, buf + i);
    uint8_t tail[128];
    size_t rest = n - i;
    memset(tail, 0, sizeof tail);
    memcpy(tail, buf + i, rest);
    tail[rest] = 0x80;
    size_t tlen = rest + 9 <= 64 ? 64 : 128;
    uint64_t bits = (uint64_t) n * 8u;
    for (int j = 0; j < 8; j++)
        tail[tlen - 1 - j] = (uint8_t) (bits >> (8 * j));
    sha256_block(h, tail);
    if (tlen == 128) sha256_block(h, tail + 64);
    for (int j = 0; j < 8; j++) {
        out[4 * j]     = (uint8_t) (h[j] >> 24);
        out[4 * j + 1] = (uint8_t) (h[j] >> 16);
        out[4 * j + 2] = (uint8_t) (h[j] >> 8);
        out[4 * j + 3] = (uint8_t) h[j];
    }
}

static inline bool varint(const uint8_t *b, size_t n, size_t *pos,
                          uint64_t *out)
{
    uint64_t v = 0;
    for (unsigned shift = 0; *pos < n && shift < 64; shift += 7) {
        uint8_t c = b[(*pos)++];
        v |= (uint64_t) (c & 0x7fu) << shift;
        if (!(c & 0x80u)) { *out = v; return true; }
    }
    return false;
}

/* The offset of the header's 32-byte `dsc_sha256` (field 7 of the DscHeader,
   which is the first atom, field 263 of Atom), or -1. The walk @ds-lang/ds's
   engine.test.mjs `sha256Offset` makes. */
static inline long sha256_offset(const uint8_t *b, size_t n)
{
    size_t pos = 1;
    uint64_t v = 0;
    if (n == 0 || b[0] != 0x0au) return -1;
    if (!varint(b, n, &pos, &v)) return -1;                   /* Atom length */
    if (!varint(b, n, &pos, &v) || v != ((263u << 3) | 2u)) return -1;
    if (!varint(b, n, &pos, &v)) return -1;                   /* header length */
    size_t end = pos + (size_t) v;
    if (end > n) return -1;
    while (pos < end) {
        if (!varint(b, n, &pos, &v)) return -1;
        uint64_t field = v >> 3, wire = v & 7u;
        if (wire == 2) {
            uint64_t len = 0;
            if (!varint(b, n, &pos, &len)) return -1;
            if (field == 7 && len == 32) return (long) pos;
            pos += (size_t) len;
        } else if (wire == 0) {
            if (!varint(b, n, &pos, &v)) return -1;
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 5) {
            pos += 4;
        } else {
            return -1;
        }
    }
    return -1;
}

/* `dsc`'s `dsc_sha256` recomputed over its edited bytes, as the compiler
   computes it ([RDSC.3.6]). 0; 1 when the header has none. */
static inline int reseal(uint8_t *dsc, size_t n)
{
    long h = sha256_offset(dsc, n);
    if (h < 0) {
        fprintf(stderr, "FAIL: the artefact has no dsc_sha256 to reseal\n");
        return 1;
    }
    memset(dsc + h, 0, 32);
    uint8_t digest[32];
    sha256(dsc, n, digest);
    memcpy(dsc + h, digest, 32);
    return 0;
}

/* ---- the lie --------------------------------------------------------------- */

static const uint8_t SLOT_INT[] = { 0x12, 0x04, 'l', 'i', 'e', 'd', 0x18, 0x01 };

/* `dsc` with slot `lied` declared String, resealed. 0; 1 when the Slot atom is
   not found exactly once or the header has no dsc_sha256. */
static inline int lie(uint8_t *dsc, size_t n)
{
    long at = -1;
    int  found = 0;
    for (size_t i = 0; i + sizeof SLOT_INT <= n; i++)
        if (memcmp(dsc + i, SLOT_INT, sizeof SLOT_INT) == 0) { at = (long) i; found++; }
    if (found != 1) {
        fprintf(stderr, "FAIL: the Slot atom for `lied` is found %d times, want 1\n",
                found);
        return 1;
    }
    dsc[at + (long) sizeof SLOT_INT - 1] = 0x03;          /* SLOT_KIND_STRING */
    return reseal(dsc, n);
}

#endif /* DS_SPEC_TAMPER_H */

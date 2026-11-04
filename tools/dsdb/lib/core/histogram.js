// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// Histograms over clock time (DSTRACE_INTERACTIVE.md §4.4 `#:`, `^:`): the
// bucket edges and each bucket's value. Arithmetic only; drawing is text/'s.
//
// Clocks and edges are BigInt nanoseconds. Bucket values are Numbers, and
// they are computed as the Python computes them: exact integer products,
// accumulated in a double, so a mean prints the same digits.

/**
 * `n + 1` edges splitting `[tLo, tHi]` into `n` buckets.
 * @param {bigint} tLo
 * @param {bigint} tHi
 * @param {number} n
 * @returns {bigint[]}
 */
export function edges(tLo, tHi, n) {
    const span = tHi - tLo > 1n ? tHi - tLo : 1n;
    const N = BigInt(n);
    const out = [];
    for (let i = 0n; i <= N; i++) out.push(tLo + floorDiv(span * i, N));
    return out;
}

/**
 * Python's `//` on BigInts: floor, not truncation.
 * @param {bigint} a
 * @param {bigint} b
 * @returns {bigint}
 */
function floorDiv(a, b) {
    const q = a / b;
    return (a % b !== 0n && (a < 0n) !== (b < 0n)) ? q - 1n : q;
}

/**
 * Summarise a step function over each bucket `[e[i], e[i+1])`.
 *
 * `changes` is `[clock, new value]` in order, starting from 0. `max` and
 * `min` include the value carried into the bucket; `mean` weights each value
 * by how long it held within the bucket, and a bucket of zero width takes its
 * maximum.
 * @param {Array<[bigint, number]>} changes
 * @param {bigint[]} e
 * @param {"max" | "min" | "mean"} how
 * @returns {number[]}
 */
export function stepBuckets(changes, e, how) {
    const out = [];
    let j = 0, cur = 0;
    for (let i = 0; i < e.length - 1; i++) {
        const a = e[i], b = e[i + 1];
        const last = i === e.length - 2;
        while (j < changes.length && changes[j][0] < a) {
            cur = changes[j][1];
            j++;
        }
        const seen = [cur];
        let t = a, acc = 0.0;
        while (j < changes.length && (changes[j][0] < b || (last && changes[j][0] <= b))) {
            const [c, v] = changes[j];
            acc += Number(BigInt(cur) * (c - t));
            t = c;
            cur = v;
            seen.push(v);
            j++;
        }
        acc += Number(BigInt(cur) * (b - t));
        if (how === "min") out.push(Math.min(...seen));
        else if (how === "mean" && b > a) out.push(acc / Number(b - a));
        else out.push(Math.max(...seen));
    }
    return out;
}

/**
 * How many of `clocks` fall in each bucket; one past the last edge counts in
 * the last bucket, as one before the first counts in the first.
 * @param {bigint[]} clocks
 * @param {bigint[]} e
 * @returns {number[]}
 */
export function countBuckets(clocks, e) {
    const out = new Array(e.length - 1).fill(0);
    for (const c of clocks) {
        const i = Math.min(out.length - 1, Math.max(0, bucketOf(c, e)));
        out[i] += 1;
    }
    return out;
}

/**
 * The bucket `c` falls in: the last edge at or before it.
 * @param {bigint} c
 * @param {bigint[]} e
 */
export function bucketOf(c, e) {
    let lo = 0, hi = e.length - 1;
    while (lo < hi - 1) {
        const mid = Math.floor((lo + hi) / 2);
        if (e[mid] <= c) lo = mid;
        else hi = mid;
    }
    return lo;
}

% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.sha256 -- SHA-256, pure, for the artefact binding hash ([RBND.1.3]).
%
% `uint32` wraps, which is SHA-256's addition modulo 2^32.
%-----------------------------------------------------------------------------%

:- module ds.sha256.
:- interface.

:- import_module bitmap.
:- import_module list.
:- import_module uint8.

%-----------------------------------------------------------------------------%

    % The digest of a byte list: 32 bytes, big-endian, as the standard defines.
    %
:- func sha256(list(uint8)) = list(uint8).

    % Fails on a bitmap whose length is not a whole number of bytes.
    %
:- pred sha256_bitmap(bitmap::in, list(uint8)::out) is semidet.

:- func hex(list(uint8)) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module string.
:- import_module uint32.
:- import_module uint64.
:- import_module require.

%-----------------------------------------------------------------------------%

sha256_bitmap(BM, Digest) :-
    N = bitmap.num_bytes(BM),
    to_bytes(BM, 0, N, [], Rev),
    Digest = sha256(list.reverse(Rev)).

:- pred to_bytes(bitmap::in, int::in, int::in,
                 list(uint8)::in, list(uint8)::out) is det.

to_bytes(BM, I, N, !Acc) :-
    ( if I < N then
        !:Acc = [uint8.cast_from_int(bitmap.byte(I, BM)) | !.Acc],
        to_bytes(BM, I + 1, N, !Acc)
    else
        true
    ).

    % The message is read in place, a block at a time; only the tail is padded.
    %
sha256(Bytes) = Digest :-
    hash_blocks(Bytes, 0, initial_h, H),
    Digest = list.condense(list.map(be32, H)).

:- pred hash_blocks(list(uint8)::in, int::in, list(uint32)::in,
                    list(uint32)::out) is det.

hash_blocks(Bytes, Len0, H0, H) :-
    ( if block_words(16, Bytes, [], Rev16, Rest) then
        compress(Rev16, H0, H1),
        hash_blocks(Rest, Len0 + 64, H1, H)
    else
        hash_tail(pad_tail(Bytes, Len0 + list.length(Bytes)), H0, H)
    ).

:- pred hash_tail(list(uint8)::in, list(uint32)::in, list(uint32)::out)
    is det.

hash_tail(Tail, H0, H) :-
    ( if block_words(16, Tail, [], Rev16, Rest) then
        compress(Rev16, H0, H1),
        hash_tail(Rest, H1, H)
    else if Tail = [] then
        H = H0
    else
        % Unreachable: `pad_tail` makes the tail a whole number of blocks.
        unexpected($pred, "the padded tail is not a whole number of blocks")
    ).

    % FIPS 180-4 §5.1.1, applied to the last `Rem` bytes of a message `Len` bytes long.
    %
:- func pad_tail(list(uint8), int) = list(uint8).

pad_tail(Rem, Len) = Rem ++ [0x80u8] ++ zeros(ZeroCount) ++ be64(BitLen) :-
    % `mod` is floor-based, so a negative numerator lands in [0, 63].
    ZeroCount = (55 - Len) mod 64,
    BitLen = uint64.cast_from_int(Len) * 8u64.

    % `N` big-endian words off the front, reversed, and what follows. Fails when fewer
    % than `4 * N` bytes remain.
    %
:- pred block_words(int::in, list(uint8)::in, list(uint32)::in,
                    list(uint32)::out, list(uint8)::out) is semidet.

block_words(N, Bytes, Acc, Rev, Rest) :-
    ( if N = 0 then
        Rev = Acc,
        Rest = Bytes
    else
        Bytes = [B0, B1, B2, B3 | More],
        Word = (uint8_to_u32(B0) << 24) \/ (uint8_to_u32(B1) << 16) \/
               (uint8_to_u32(B2) << 8) \/ uint8_to_u32(B3),
        block_words(N - 1, More, [Word | Acc], Rev, Rest)
    ).

:- func zeros(int) = list(uint8).

zeros(N) = ( if N =< 0 then [] else [0u8 | zeros(N - 1)] ).

:- func be64(uint64) = list(uint8).

be64(V) = list.map(
    (func(Shift) = uint8.cast_from_int(uint64.cast_to_int(
        (V >> Shift) /\ 0xFFu64))),
    [56, 48, 40, 32, 24, 16, 8, 0]).

:- func be32(uint32) = list(uint8).

be32(V) = list.map(
    (func(Shift) = uint8.cast_from_int(uint32.cast_to_int(
        (V >> Shift) /\ 0xFFu32))),
    [24, 16, 8, 0]).

:- func initial_h = list(uint32).

initial_h = [0x6a09e667u32, 0xbb67ae85u32, 0x3c6ef372u32, 0xa54ff53au32,
             0x510e527fu32, 0x9b05688cu32, 0x1f83d9abu32, 0x5be0cd19u32].

:- pred compress(list(uint32)::in, list(uint32)::in, list(uint32)::out) is det.

compress(Rev16, H0, H) :-
    ( if
        Rev16 = [W15, W14, W13, W12, W11, W10, W9, W8,
                 W7, W6, W5, W4, W3, W2, W1, W0],
        H0 = [A0, B0, C0, D0, E0, F0, G0, I0]
    then
        rounds(k_constants, W0, W1, W2, W3, W4, W5, W6, W7,
            W8, W9, W10, W11, W12, W13, W14, W15,
            A0, B0, C0, D0, E0, F0, G0, I0, A, B, C, D, E, F, G, I),
        H = [A0 + A, B0 + B, C0 + C, D0 + D,
             E0 + E, F0 + F, G0 + G, I0 + I]
    else
        unexpected($pred, "a block is not sixteen words or the state eight")
    ).

:- func uint8_to_u32(uint8) = uint32.

uint8_to_u32(B) = uint32.cast_from_int(uint8.cast_to_int(B)).

    % The sixty-four rounds, FIPS 180-4 §6.2.2. No message schedule is built: `W0` ..
    % `W15` are a window `W[t]` .. `W[t+15]`, slid by one with `W[t+16]` from step 1's
    % recurrence. The last sixteen rounds compute words nothing reads.
    %
:- pred rounds(list(uint32)::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::in, uint32::in, uint32::in, uint32::in,
               uint32::out, uint32::out, uint32::out, uint32::out,
               uint32::out, uint32::out, uint32::out, uint32::out) is det.

rounds([], _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _,
       A, B, C, D, E, F, G, H, A, B, C, D, E, F, G, H).
rounds([K | Ks], W0, W1, W2, W3, W4, W5, W6, W7,
       W8, W9, W10, W11, W12, W13, W14, W15,
       A0, B0, C0, D0, E0, F0, G0, H0, A, B, C, D, E, F, G, H) :-
    T1 = H0 + big_sigma1(E0) + ch(E0, F0, G0) + K + W0,
    T2 = big_sigma0(A0) + maj(A0, B0, C0),
    W16 = small_sigma1(W14) + W9 + small_sigma0(W1) + W0,
    rounds(Ks, W1, W2, W3, W4, W5, W6, W7, W8,
        W9, W10, W11, W12, W13, W14, W15, W16,
        T1 + T2, A0, B0, C0, D0 + T1, E0, F0, G0,
        A, B, C, D, E, F, G, H).

%-----------------------------------------------------------------------------%
% The functions of FIPS 180-4 §4.1.2
%-----------------------------------------------------------------------------%

:- func rotr(uint32, int) = uint32.

rotr(V, N) = (V >> N) \/ (V << (32 - N)).

:- func ch(uint32, uint32, uint32) = uint32.

ch(X, Y, Z) = uint32.xor(X /\ Y, (\ X) /\ Z).

:- func maj(uint32, uint32, uint32) = uint32.

maj(X, Y, Z) = uint32.xor(uint32.xor(X /\ Y, X /\ Z), Y /\ Z).

:- func big_sigma0(uint32) = uint32.

big_sigma0(X) = uint32.xor(uint32.xor(rotr(X, 2), rotr(X, 13)), rotr(X, 22)).

:- func big_sigma1(uint32) = uint32.

big_sigma1(X) = uint32.xor(uint32.xor(rotr(X, 6), rotr(X, 11)), rotr(X, 25)).

:- func small_sigma0(uint32) = uint32.

small_sigma0(X) = uint32.xor(uint32.xor(rotr(X, 7), rotr(X, 18)), X >> 3).

:- func small_sigma1(uint32) = uint32.

small_sigma1(X) = uint32.xor(uint32.xor(rotr(X, 17), rotr(X, 19)), X >> 10).

%-----------------------------------------------------------------------------%

:- func k_constants = list(uint32).

k_constants = [
    0x428a2f98u32, 0x71374491u32, 0xb5c0fbcfu32, 0xe9b5dba5u32,
    0x3956c25bu32, 0x59f111f1u32, 0x923f82a4u32, 0xab1c5ed5u32,
    0xd807aa98u32, 0x12835b01u32, 0x243185beu32, 0x550c7dc3u32,
    0x72be5d74u32, 0x80deb1feu32, 0x9bdc06a7u32, 0xc19bf174u32,
    0xe49b69c1u32, 0xefbe4786u32, 0x0fc19dc6u32, 0x240ca1ccu32,
    0x2de92c6fu32, 0x4a7484aau32, 0x5cb0a9dcu32, 0x76f988dau32,
    0x983e5152u32, 0xa831c66du32, 0xb00327c8u32, 0xbf597fc7u32,
    0xc6e00bf3u32, 0xd5a79147u32, 0x06ca6351u32, 0x14292967u32,
    0x27b70a85u32, 0x2e1b2138u32, 0x4d2c6dfcu32, 0x53380d13u32,
    0x650a7354u32, 0x766a0abbu32, 0x81c2c92eu32, 0x92722c85u32,
    0xa2bfe8a1u32, 0xa81a664bu32, 0xc24b8b70u32, 0xc76c51a3u32,
    0xd192e819u32, 0xd6990624u32, 0xf40e3585u32, 0x106aa070u32,
    0x19a4c116u32, 0x1e376c08u32, 0x2748774cu32, 0x34b0bcb5u32,
    0x391c0cb3u32, 0x4ed8aa4au32, 0x5b9cca4fu32, 0x682e6ff3u32,
    0x748f82eeu32, 0x78a5636fu32, 0x84c87814u32, 0x8cc70208u32,
    0x90befffau32, 0xa4506cebu32, 0xbef9a3f7u32, 0xc67178f2u32].

%-----------------------------------------------------------------------------%

hex(Bytes) = string.append_list(list.map(hex_byte, Bytes)).

:- func hex_byte(uint8) = string.

hex_byte(B) = string.format("%02x", [i(uint8.cast_to_int(B))]).

%-----------------------------------------------------------------------------%

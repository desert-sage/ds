% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.id -- opaque identifiers.
%
% Every identifier the wire carries as a bare uint32 gets its own type.
% Construction of one that reserves zero is `semidet` and rejects it.
%-----------------------------------------------------------------------------%

:- module ds.id.
:- interface.

:- import_module list.
:- import_module maybe.

%-----------------------------------------------------------------------------%
% Bundle-global identifiers
%-----------------------------------------------------------------------------%

    % A Rete node: alpha, beta and terminal share one bundle-global namespace
    % [RDSC.4a.3].
    %
:- type node_id.
:- pred node_id(uint32::in, node_id::out) is semidet.
:- func node_id_value(node_id) = uint32.

    % An expression-DAG node [RDSC.4a.3]: a different namespace from node_id.
    %
:- type expr_id.
:- pred expr_id(uint32::in, expr_id::out) is semidet.
:- func expr_id_value(expr_id) = uint32.

    % A terminal node [RDSC.4a.3], drawn from the node_id namespace.
    %
:- type term_id == node_id.

    % A source module, the per-module join key [RDSC.4.7].
    %
:- type module_id.
:- pred module_id(uint32::in, module_id::out) is semidet.
:- func module_id_value(module_id) = uint32.

%-----------------------------------------------------------------------------%
% Engine-local identifiers
%-----------------------------------------------------------------------------%

    % A registered schema, assigned at load. The wire identifies schemas by NFC
    % name [RFCS.6.5].
    %
:- type schema_id.

    % A slot's position within its schema, zero-based. A schema may hold more
    % slots than a wire field can address; a field's own range is `ds.expr`'s
    % `wire_*` readers'.
    %
:- type slot_index.
:- pred slot_index(uint32::in, slot_index::out) is semidet.
:- func slot_index_value(slot_index) = uint32.

:- func slot_index_int(slot_index) = int.

    % [RDSC.4a.9.1]: a slot or pattern index on the wire holds 0..254, and 255 is
    % the marker in the fields that have one. A schema holds at most that many
    % slots ([LGRA.5.11]) and a rule that many patterns ([LGRA.8.7]).
    %
:- func rdsc_4a_9_1_index_count = int.
:- func rdsc_4a_9_1_marker = uint32.

    % A fact's identity within one engine. A no-op reassertion preserves it
    % [LFAC.2.5.1]; a meaningful change mints a fresh one [LFAC.2.5.3].
    % A recorded stream's fact_id is file-scoped [RFCS.6.4].
    %
:- type fact_id.

    % A match's creation timetag [LDET.5.5], the agenda's second key. An activation
    % inherits its token's.
    %
:- type timetag.

    % A stream sequence number [LFST.7.1.1]: assigned atomically with the record
    % append, from 0, strictly increasing and contiguous
    % [formal/tla/stream_seq.tla].
    %
:- type seq.

:- type intern_ref.

%-----------------------------------------------------------------------------%
% Minting engine-local identifiers
%-----------------------------------------------------------------------------%

    % `make_`: a function and a data constructor of one name and arity are
    % ambiguous in the defining clause.
    %
:- func make_fact_id(uint64) = fact_id.
:- func make_timetag(uint64) = timetag.
:- func make_seq(uint64) = seq.
:- func make_schema_id(uint32) = schema_id.
:- func make_intern_ref(uint32) = intern_ref.

:- func fact_id_value(fact_id) = uint64.

    % For a hashed index keyed on a fact id ([LNLS.4.7]).
    %
:- pred fact_id_hash(fact_id::in, int::out) is det.

    % A positional hash of a fact tuple, for the indexes keyed on a match.
    %
:- func fact_tuple_hash(uint64, list(fact_id)) = uint64.

:- func timetag_value(timetag) = uint64.
:- func seq_value(seq) = uint64.
:- func schema_id_value(schema_id) = uint32.
:- func intern_ref_value(intern_ref) = uint32.

%-----------------------------------------------------------------------------%
% Sentinels made explicit
%-----------------------------------------------------------------------------%

    % A beta node's left parent. `left_parent_id == 0` marks a root beta, seeded
    % with a nil token [RDSC.4a.7].
    %
:- type beta_parent == maybe(node_id).

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module uint32.
:- import_module uint64.
:- import_module int.

:- type node_id     ---> node_id(uint32).
:- type expr_id     ---> expr_id(uint32).
:- type module_id   ---> module_id(uint32).
:- type slot_index  ---> slot_index(uint32).

:- type schema_id   ---> schema_id(uint32).
:- type fact_id     ---> fact_id(uint64).
:- type timetag     ---> timetag(uint64).
:- type seq         ---> seq(uint64).
:- type intern_ref  ---> intern_ref(uint32).

node_id(N, node_id(N)) :- N \= 0u32.
expr_id(N, expr_id(N)) :- N \= 0u32.
module_id(N, module_id(N)) :- N \= 0u32.

    % A position in a schema of at most 65 535 slots.
    %
slot_index(N, slot_index(N)) :- N < 0xFFFFu32.

node_id_value(node_id(N)) = N.
expr_id_value(expr_id(N)) = N.
module_id_value(module_id(N)) = N.
slot_index_value(slot_index(N)) = N.
slot_index_int(slot_index(N)) = uint32.cast_to_int(N).

rdsc_4a_9_1_index_count = 255.
rdsc_4a_9_1_marker = 255u32.

make_fact_id(N) = fact_id(N).

fact_id_hash(fact_id(Z0), Hash) :-
    % splitmix64's finaliser; non-negative, for a hash table's slot arithmetic.
    Z1 = (Z0 `xor` (Z0 >> 30)) * 0xbf58476d1ce4e5b9u64,
    Z2 = (Z1 `xor` (Z1 >> 27)) * 0x94d049bb133111ebu64,
    Z = Z2 `xor` (Z2 >> 31),
    Hash = uint64.cast_to_int(Z >> 1).

fact_tuple_hash(Seed, Ids) = list.foldl(mix_in, Ids, Seed).

:- func mix_in(fact_id, uint64) = uint64.

mix_in(fact_id(X), H) = Z :-
    Z0 = (H * 31u64) `xor` X,
    Z1 = (Z0 `xor` (Z0 >> 30)) * 0xbf58476d1ce4e5b9u64,
    Z2 = (Z1 `xor` (Z1 >> 27)) * 0x94d049bb133111ebu64,
    Z = Z2 `xor` (Z2 >> 31).
make_timetag(N) = timetag(N).
make_seq(N) = seq(N).
make_schema_id(N) = schema_id(N).
make_intern_ref(N) = intern_ref(N).

fact_id_value(fact_id(N)) = N.
timetag_value(timetag(N)) = N.
seq_value(seq(N)) = N.
schema_id_value(schema_id(N)) = N.
intern_ref_value(intern_ref(N)) = N.

%-----------------------------------------------------------------------------%

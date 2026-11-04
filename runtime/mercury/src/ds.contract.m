% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.contract -- the `RealtimeContract` realtime contract, and its canonical serialization.
%
% The hash is over the logical contract [RBND.4b.8]: expand before serializing,
% so the two node encodings hash identically.
%-----------------------------------------------------------------------------%

:- module ds.contract.
:- interface.

:- import_module ds.network.
:- import_module ds.wire.
:- import_module list.
:- import_module string.
:- import_module uint8.

%-----------------------------------------------------------------------------%

:- type node_cap
    --->    node_cap(
                nc_id       :: uint32,
                nc_kind     :: string,      % "alpha" | "beta" | "term"
                nc_capacity :: uint32
            ).

:- type series_cap
    --->    series_cap(
                sc_id       :: uint32,
                sc_capacity :: uint32
            ).

:- type contract
    --->    contract(
                c_wm_max           :: uint32,
                c_agenda_cap       :: uint32,
                c_max_fires        :: uint32,
                c_token_pool_cap   :: uint32,
                c_intern_cap       :: uint32,
                c_intern_bytes_cap :: uint32,
                c_pump_wcet_ns     :: uint64,
                c_nodes            :: list(node_cap),
                c_series           :: list(series_cap),
                c_stored_sha       :: list(uint8),
                c_cache_cap        :: uint32,
                c_cache_bytes_cap  :: uint64,
                c_node_count       :: uint32,
                c_default_cap      :: uint32,
                c_overrides        :: list(node_cap),  % id + capacity; kind ""
                c_packed           :: list(uint32)
            ).

:- pred decode_contract(reader::in, contract::out) is semidet.

    % Where the cache caps go in the canonical serialization: `appended` is what
    % reproduces a `+realtime` artefact's own `rt_config_sha256`.
    %
:- type cap_placement
    --->    after_intern
    ;       appended.

    % [RBND.4b.2].
    %
:- func canonical(contract, cap_placement) = string.

:- func canonical_placement = cap_placement.

    % [RBND.4b.8]'s list, from whichever encoding the atom used. The compact one
    % has no kinds, so this takes them from the network.
    %
:- func expand_nodes(network, contract) = list(node_cap).

    % The contract with `c_nodes` expanded. A legacy artefact's list is kept:
    % `expand_nodes` reads `c_packed`, so it would make every node unlimited.
    %
:- func expanded(network, contract) = contract.

    % [RTCT.6.5]'s third obligation. Not checkable when the atom is read: it comes
    % before the network ([RTCT.6.4]).
    %
:- pred contract_hash_ok(network::in, contract::in) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module int.
:- import_module uint32.
:- import_module uint64.
:- import_module ds.id.
:- import_module ds.sha256.
:- import_module assoc_list.
:- import_module char.
:- import_module pair.

%-----------------------------------------------------------------------------%

decode_contract(R, C) :-
    Blank = contract(0u32, 0u32, 0u32, 0u32, 0u32, 0u32, 0u64, [], [], [],
        0u32, 0u64, 0u32, 0u32, [], []),
    fold_fields(R, contract_field, Blank, ff_ok(C)).

:- pred contract_field(uint32::in, field_value::in,
                       contract::in, contract::out) is semidet.

contract_field(Num, Value, !C) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), !C ^ c_wm_max := u32(V)
    else if Num = 2u32 then
        Value = fv_varint(V), !C ^ c_agenda_cap := u32(V)
    else if Num = 3u32 then
        Value = fv_varint(V), !C ^ c_max_fires := u32(V)
    else if Num = 4u32 then
        Value = fv_varint(V), !C ^ c_token_pool_cap := u32(V)
    else if Num = 5u32 then
        Value = fv_varint(V), !C ^ c_intern_cap := u32(V)
    else if Num = 6u32 then
        Value = fv_varint(V), !C ^ c_intern_bytes_cap := u32(V)
    else if Num = 7u32 then
        Value = fv_varint(V), !C ^ c_pump_wcet_ns := V
    else if Num = 8u32 then
        Value = fv_bytes(Sub), decode_node(Sub, N),
        !C ^ c_nodes := !.C ^ c_nodes ++ [N]
    else if Num = 9u32 then
        Value = fv_bytes(Sub), decode_series(Sub, S),
        !C ^ c_series := !.C ^ c_series ++ [S]
    else if Num = 10u32 then
        Value = fv_bytes(Sub), !C ^ c_stored_sha := reader_bytes(Sub)
    else if Num = 11u32 then
        Value = fv_varint(V), !C ^ c_node_count := u32(V)
    else if Num = 12u32 then
        Value = fv_varint(V), !C ^ c_default_cap := u32(V)
    else if Num = 13u32 then
        Value = fv_bytes(Sub), decode_override(Sub, N2),
        !C ^ c_overrides := !.C ^ c_overrides ++ [N2]
    else if Num = 14u32 then
        Value = fv_bytes(Sub), read_packed_varints(Sub, ok(Vs)),
        !C ^ c_packed := !.C ^ c_packed ++ list.map(u32, Vs)
    else if Num = 15u32 then
        Value = fv_varint(V), !C ^ c_cache_cap := u32(V)
    else if Num = 16u32 then
        Value = fv_varint(V), !C ^ c_cache_bytes_cap := V
    else
        true
    ).

:- func u32(uint64) = uint32.

u32(V) = uint32.cast_from_uint64(V).

:- pred decode_node(reader::in, node_cap::out) is semidet.

decode_node(R, N) :-
    fold_fields(R, node_field, node_cap(0u32, "", 0u32), ff_ok(N)).

:- pred node_field(uint32::in, field_value::in,
                   node_cap::in, node_cap::out) is semidet.

node_field(Num, Value, !N) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), !N ^ nc_id := u32(V)
    else if Num = 2u32 then
        Value = fv_bytes(S), reader_string(S, K), !N ^ nc_kind := K
    else if Num = 3u32 then
        Value = fv_varint(V), !N ^ nc_capacity := u32(V)
    else
        true
    ).

    % Not a `NodeCap`: field 2 here is the capacity, a varint, not the kind
    % [RTCT.6.7].
    %
:- pred decode_override(reader::in, node_cap::out) is semidet.

decode_override(R, N) :-
    fold_fields(R, override_field, node_cap(0u32, "", 0u32), ff_ok(N)).

:- pred override_field(uint32::in, field_value::in,
                       node_cap::in, node_cap::out) is semidet.

override_field(Num, Value, !N) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), !N ^ nc_id := u32(V)
    else if Num = 2u32 then
        Value = fv_varint(V), !N ^ nc_capacity := u32(V)
    else
        true
    ).

:- pred decode_series(reader::in, series_cap::out) is semidet.

decode_series(R, S) :-
    fold_fields(R, series_field, series_cap(0u32, 0u32), ff_ok(S)).

:- pred series_field(uint32::in, field_value::in,
                     series_cap::in, series_cap::out) is semidet.

series_field(Num, Value, !S) :-
    ( if Num = 1u32 then
        Value = fv_varint(V), !S ^ sc_id := u32(V)
    else if Num = 2u32 then
        Value = fv_varint(V), !S ^ sc_capacity := u32(V)
    else
        true
    ).

%-----------------------------------------------------------------------------%

canonical_placement = appended.

canonical(C, Placement) = Text :-
    Caps = cap_lines(C),
    (
        Placement = after_intern,
        Head = scalars_to_intern(C) ++ Caps ++ [wcet_line(C)]
    ;
        Placement = appended,
        Head = scalars_to_intern(C) ++ [wcet_line(C)]
    ),
    Tail = [nodes_line(C), series_line(C)],
    (
        Placement = after_intern,
        Lines = Head ++ Tail
    ;
        Placement = appended,
        Lines = Head ++ Tail ++ Caps
    ),
    Text = "ds.contract.v1\n" ++ string.append_list(Lines).

:- func scalars_to_intern(contract) = list(string).

scalars_to_intern(C) = [
    line("wm_max", u64(C ^ c_wm_max)),
    line("agenda_cap", u64(C ^ c_agenda_cap)),
    line("max_fires_per_pump", u64(C ^ c_max_fires)),
    line("token_pool_cap", u64(C ^ c_token_pool_cap)),
    line("intern_cap", u64(C ^ c_intern_cap)),
    line("intern_bytes_cap", u64(C ^ c_intern_bytes_cap))].

:- func wcet_line(contract) = string.

wcet_line(C) = line("pump_wcet_ns", C ^ c_pump_wcet_ns).

    % A zero cap contributes no line ([RTCT.6.8.1]).
    %
:- func cap_lines(contract) = list(string).

cap_lines(C) =
    ( if C ^ c_cache_cap = 0u32 then [] else
        [line("cache_cap", u64(C ^ c_cache_cap))] ) ++
    ( if C ^ c_cache_bytes_cap = 0u64 then [] else
        [line("cache_bytes_cap", C ^ c_cache_bytes_cap)] ).

:- func line(string, uint64) = string.

line(Name, V) = string.append_list([Name, "=", u64_str(V), "\n"]).

:- func u64(uint32) = uint64.

u64(V) = uint32.cast_to_uint64(V).

:- func u64_str(uint64) = string.

u64_str(V) = string.from_int(uint64.cast_to_int(V)).

:- func nodes_line(contract) = string.

nodes_line(C) = "nodes=" ++
    string.join_list(",", list.map(node_text, C ^ c_nodes)) ++ "\n".

:- func node_text(node_cap) = string.

node_text(N) =
    u64_str(u64(N ^ nc_id)) ++ ":" ++ N ^ nc_kind ++ ":" ++
    u64_str(u64(N ^ nc_capacity)).

:- func series_line(contract) = string.

series_line(C) = "series=" ++
    string.join_list(",", list.map(series_text, C ^ c_series)) ++ "\n".

:- func series_text(series_cap) = string.

series_text(S) =
    u64_str(u64(S ^ sc_id)) ++ ":" ++
    u64_str(u64(S ^ sc_capacity)).

%-----------------------------------------------------------------------------%

%-----------------------------------------------------------------------------%
% The materialized logical contract, and the hash over it
%-----------------------------------------------------------------------------%

expand_nodes(Net, C) = Nodes :-
    % Node ids are bundle-global, so the kinds interleave.
    Ids = list.sort(
        list.map((func(A) = uint32.cast_to_int(node_id_value(A ^ an_id))
                            - "alpha"), alpha_nodes(Net)) ++
        list.map((func(B) = uint32.cast_to_int(node_id_value(B ^ bn_id))
                            - "beta"), beta_nodes(Net)) ++
        list.map((func(T) = uint32.cast_to_int(node_id_value(T ^ tn_id))
                            - "term"), terminal_nodes(Net))),
    Nodes = zip_caps(Ids, C ^ c_packed, C ^ c_default_cap, C ^ c_overrides).

    % Positionally, then the default once `Packed` runs out. An override wins
    % over a positional capacity.
    %
:- func zip_caps(assoc_list(int, string), list(uint32), uint32,
                 list(node_cap)) = list(node_cap).

zip_caps([], _, _, _) = [].
zip_caps([Id - Kind | Rest], Packed, Default, Overrides)
        = [N | zip_caps(Rest, Tail, Default, Overrides)] :-
    (
        Packed = [Positional | Tail]
    ;
        Packed = [],
        Positional = Default, Tail = []
    ),
    ( if
        list.find_first_match(
            (pred(O::in) is semidet :-
                uint32.cast_to_int(O ^ nc_id) = Id),
            Overrides, Found)
    then
        Cap = Found ^ nc_capacity
    else
        Cap = Positional
    ),
    N = node_cap(uint32.det_from_int(Id), Kind, Cap).

expanded(Net, C) =
    ( if C ^ c_packed = [], C ^ c_nodes = [_ | _] then
        C
    else
        C ^ c_nodes := expand_nodes(Net, C)
    ).

contract_hash_ok(Net, C) :-
    Text = canonical(expanded(Net, C), canonical_placement),
    Digest = sha256(list.map(char_byte, string.to_char_list(Text))),
    Digest = C ^ c_stored_sha.

    % The canonical serialization is ASCII by construction.
    %
:- func char_byte(char) = uint8.

char_byte(Ch) = uint8.det_from_int(char.to_int(Ch)).

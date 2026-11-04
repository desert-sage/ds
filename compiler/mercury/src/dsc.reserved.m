%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% dsc.reserved -- GENERATED. Do not edit: regenerate it.
%
% [LLEX.9.6]'s reserved words, one fact per row of the clause's `data` table.
%
% 158 rows; sha256 (first 16) of the rows as JSON: 707c1e24d84f559c.
% The `p1` .. `p99` family has no row ([LLEX.9.5]) and is not here.
%-----------------------------------------------------------------------------%

:- module dsc.reserved.
:- interface.

    %@helper
:- type reserved_by
    --->    rb_grammar
    ;       rb_aggregation
    ;       rb_alias
    ;       rb_builtin
    ;       rb_kwarg
    ;       rb_type.

    %@spec [LLEX.9.6]
:- pred llex_9_6_reserved_word(string::in, reserved_by::out) is semidet.

%-----------------------------------------------------------------------------%
:- implementation.

llex_9_6_reserved_word("abs", rb_builtin).
llex_9_6_reserved_word("activated", rb_grammar).
llex_9_6_reserved_word("activation", rb_grammar).
llex_9_6_reserved_word("active_fraction", rb_aggregation).
llex_9_6_reserved_word("after", rb_grammar).
llex_9_6_reserved_word("alias", rb_grammar).
llex_9_6_reserved_word("all_time", rb_grammar).
llex_9_6_reserved_word("ambient", rb_grammar).
llex_9_6_reserved_word("and", rb_grammar).
llex_9_6_reserved_word("as", rb_grammar).
llex_9_6_reserved_word("at", rb_grammar).
llex_9_6_reserved_word("base", rb_grammar).
llex_9_6_reserved_word("Bool", rb_type).
llex_9_6_reserved_word("bool_and", rb_aggregation).
llex_9_6_reserved_word("bool_or", rb_aggregation).
llex_9_6_reserved_word("by", rb_grammar).
llex_9_6_reserved_word("Bytes", rb_type).
llex_9_6_reserved_word("cache", rb_grammar).
llex_9_6_reserved_word("cache_delete", rb_grammar).
llex_9_6_reserved_word("cache_deleted", rb_grammar).
llex_9_6_reserved_word("cached", rb_grammar).
llex_9_6_reserved_word("call", rb_grammar).
llex_9_6_reserved_word("called", rb_grammar).
llex_9_6_reserved_word("capacity", rb_grammar).
llex_9_6_reserved_word("ComputationError", rb_type).
llex_9_6_reserved_word("const", rb_grammar).
llex_9_6_reserved_word("contains", rb_grammar).
llex_9_6_reserved_word("cooldown", rb_grammar).
llex_9_6_reserved_word("count", rb_grammar).
llex_9_6_reserved_word("count_distinct", rb_aggregation).
llex_9_6_reserved_word("count_of", rb_aggregation).
llex_9_6_reserved_word("Date", rb_type).
llex_9_6_reserved_word("default", rb_grammar).
llex_9_6_reserved_word("dimension", rb_grammar).
llex_9_6_reserved_word("direction", rb_aggregation).
llex_9_6_reserved_word("Duration", rb_type).
llex_9_6_reserved_word("dwell", rb_alias).
llex_9_6_reserved_word("emit", rb_grammar).
llex_9_6_reserved_word("emitted", rb_grammar).
llex_9_6_reserved_word("empty", rb_grammar).
llex_9_6_reserved_word("error", rb_grammar).
llex_9_6_reserved_word("explicit", rb_grammar).
llex_9_6_reserved_word("false", rb_grammar).
llex_9_6_reserved_word("field", rb_grammar).
llex_9_6_reserved_word("filter", rb_kwarg).
llex_9_6_reserved_word("filter_fields", rb_grammar).
llex_9_6_reserved_word("first", rb_aggregation).
llex_9_6_reserved_word("Float", rb_type).
llex_9_6_reserved_word("for", rb_grammar).
llex_9_6_reserved_word("formula", rb_grammar).
llex_9_6_reserved_word("from", rb_grammar).
llex_9_6_reserved_word("from_base", rb_grammar).
llex_9_6_reserved_word("fx_pair", rb_grammar).
llex_9_6_reserved_word("gap", rb_grammar).
llex_9_6_reserved_word("has", rb_grammar).
llex_9_6_reserved_word("hold", rb_grammar).
llex_9_6_reserved_word("hydrates", rb_grammar).
llex_9_6_reserved_word("hydration", rb_grammar).
llex_9_6_reserved_word("implicit", rb_grammar).
llex_9_6_reserved_word("import", rb_grammar).
llex_9_6_reserved_word("in", rb_grammar).
llex_9_6_reserved_word("inf", rb_grammar).
llex_9_6_reserved_word("initial", rb_grammar).
llex_9_6_reserved_word("inputs", rb_grammar).
llex_9_6_reserved_word("Int", rb_type).
llex_9_6_reserved_word("integral", rb_aggregation).
llex_9_6_reserved_word("Interval", rb_type).
llex_9_6_reserved_word("inverting", rb_grammar).
llex_9_6_reserved_word("is", rb_grammar).
llex_9_6_reserved_word("Json", rb_type).
llex_9_6_reserved_word("key", rb_grammar).
llex_9_6_reserved_word("kwarg", rb_grammar).
llex_9_6_reserved_word("last", rb_aggregation).
llex_9_6_reserved_word("latest", rb_grammar).
llex_9_6_reserved_word("len", rb_builtin).
llex_9_6_reserved_word("let", rb_grammar).
llex_9_6_reserved_word("limit", rb_kwarg).
llex_9_6_reserved_word("literal", rb_grammar).
llex_9_6_reserved_word("log", rb_grammar).
llex_9_6_reserved_word("logged", rb_grammar).
llex_9_6_reserved_word("logical", rb_grammar).
llex_9_6_reserved_word("max", rb_aggregation).
llex_9_6_reserved_word("max_limit", rb_grammar).
llex_9_6_reserved_word("max_window", rb_grammar).
llex_9_6_reserved_word("mean", rb_aggregation).
llex_9_6_reserved_word("median", rb_aggregation).
llex_9_6_reserved_word("min", rb_aggregation).
llex_9_6_reserved_word("monotonic_ns", rb_builtin).
llex_9_6_reserved_word("mutable", rb_grammar).
llex_9_6_reserved_word("nan", rb_grammar).
llex_9_6_reserved_word("NaN", rb_grammar).
llex_9_6_reserved_word("never", rb_grammar).
llex_9_6_reserved_word("no", rb_grammar).
llex_9_6_reserved_word("nocooldown", rb_kwarg).
llex_9_6_reserved_word("none", rb_grammar).
llex_9_6_reserved_word("not", rb_grammar).
llex_9_6_reserved_word("now", rb_builtin).
llex_9_6_reserved_word("null", rb_grammar).
llex_9_6_reserved_word("on", rb_grammar).
llex_9_6_reserved_word("onset_rate", rb_aggregation).
llex_9_6_reserved_word("opaque", rb_grammar).
llex_9_6_reserved_word("or", rb_grammar).
llex_9_6_reserved_word("over", rb_grammar).
llex_9_6_reserved_word("overlaps", rb_grammar).
llex_9_6_reserved_word("persist", rb_grammar).
llex_9_6_reserved_word("produces", rb_grammar).
llex_9_6_reserved_word("pstdev", rb_aggregation).
llex_9_6_reserved_word("publish", rb_grammar).
llex_9_6_reserved_word("published", rb_grammar).
llex_9_6_reserved_word("pvariance", rb_aggregation).
llex_9_6_reserved_word("rate", rb_aggregation).
llex_9_6_reserved_word("record_event", rb_grammar).
llex_9_6_reserved_word("recorded", rb_grammar).
llex_9_6_reserved_word("required", rb_grammar).
llex_9_6_reserved_word("response", rb_grammar).
llex_9_6_reserved_word("responses", rb_grammar).
llex_9_6_reserved_word("retain", rb_kwarg).
llex_9_6_reserved_word("retained", rb_grammar).
llex_9_6_reserved_word("retracted", rb_grammar).
llex_9_6_reserved_word("round", rb_builtin).
llex_9_6_reserved_word("rule", rb_grammar).
llex_9_6_reserved_word("sample", rb_grammar).
llex_9_6_reserved_word("sampled", rb_grammar).
llex_9_6_reserved_word("scalar", rb_grammar).
llex_9_6_reserved_word("Schema", rb_type).
llex_9_6_reserved_word("schema", rb_grammar).
llex_9_6_reserved_word("scope", rb_grammar).
llex_9_6_reserved_word("series", rb_grammar).
llex_9_6_reserved_word("service", rb_grammar).
llex_9_6_reserved_word("skip", rb_grammar).
llex_9_6_reserved_word("sliding", rb_grammar).
llex_9_6_reserved_word("stdev", rb_aggregation).
llex_9_6_reserved_word("storage", rb_grammar).
llex_9_6_reserved_word("String", rb_type).
llex_9_6_reserved_word("sum", rb_aggregation).
llex_9_6_reserved_word("test", rb_grammar).
llex_9_6_reserved_word("then", rb_grammar).
llex_9_6_reserved_word("Time", rb_type).
llex_9_6_reserved_word("timeout", rb_grammar).
llex_9_6_reserved_word("to", rb_grammar).
llex_9_6_reserved_word("to_base", rb_grammar).
llex_9_6_reserved_word("tolerance", rb_grammar).
llex_9_6_reserved_word("true", rb_grammar).
llex_9_6_reserved_word("ttl", rb_grammar).
llex_9_6_reserved_word("tumbling", rb_grammar).
llex_9_6_reserved_word("type", rb_grammar).
llex_9_6_reserved_word("TypeError", rb_type).
llex_9_6_reserved_word("unit", rb_grammar).
llex_9_6_reserved_word("until", rb_grammar).
llex_9_6_reserved_word("use", rb_grammar).
llex_9_6_reserved_word("value", rb_kwarg).
llex_9_6_reserved_word("variance", rb_aggregation).
llex_9_6_reserved_word("via", rb_grammar).
llex_9_6_reserved_word("where", rb_grammar).
llex_9_6_reserved_word("withdraw", rb_grammar).
llex_9_6_reserved_word("within", rb_grammar).
llex_9_6_reserved_word("wm", rb_grammar).
llex_9_6_reserved_word("zero", rb_grammar).

%-----------------------------------------------------------------------------%
:- end_module dsc.reserved.
%-----------------------------------------------------------------------------%

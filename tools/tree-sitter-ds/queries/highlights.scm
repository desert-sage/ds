; SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
; SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
;
; GENERATED from [LLEX.9.6], [LEXP.17.2] and grammar.js. Do not edit: regenerate it.

(comment) @comment
(string) @string
[(escape_sequence) (brace_escape)] @string.escape
(interpolation (identifier) @variable)
(format_spec) @string.special
(regex) @string.regexp
[(integer) (float) (unit_literal)] @number

; declarations and the names they declare
(schema_declaration name: (identifier) @type.definition)
(rule_declaration name: (identifier) @function)
(service_declaration name: (dotted_name) @function)
(const_declaration name: (identifier) @constant)
(field_declaration name: (identifier) @variable.member)
(type_ref) @type
(type) @type
(attribute attribute: (identifier) @variable.member)
(kwarg name: (identifier) @variable.parameter)
(flag) @attribute

; [LLEX.9.6]'s types, builtins and aggregations, and [LEXP.17.2]'s dotted builtins
((identifier) @type.builtin (#any-of? @type.builtin "Bool" "Bytes" "ComputationError" "Date" "Duration" "Float" "Int" "Interval" "Json" "Schema" "String" "Time" "TypeError"))
(call function: (identifier) @function.builtin (#any-of? @function.builtin "abs" "active_fraction" "bool_and" "bool_or" "count_distinct" "count_of" "direction" "dwell" "first" "integral" "last" "len" "max" "mean" "median" "min" "monotonic_ns" "now" "onset_rate" "p1" "p10" "p11" "p12" "p13" "p14" "p15" "p16" "p17" "p18" "p19" "p2" "p20" "p21" "p22" "p23" "p24" "p25" "p26" "p27" "p28" "p29" "p3" "p30" "p31" "p32" "p33" "p34" "p35" "p36" "p37" "p38" "p39" "p4" "p40" "p41" "p42" "p43" "p44" "p45" "p46" "p47" "p48" "p49" "p5" "p50" "p51" "p52" "p53" "p54" "p55" "p56" "p57" "p58" "p59" "p6" "p60" "p61" "p62" "p63" "p64" "p65" "p66" "p67" "p68" "p69" "p7" "p70" "p71" "p72" "p73" "p74" "p75" "p76" "p77" "p78" "p79" "p8" "p80" "p81" "p82" "p83" "p84" "p85" "p86" "p87" "p88" "p89" "p9" "p90" "p91" "p92" "p93" "p94" "p95" "p96" "p97" "p98" "p99" "pstdev" "pvariance" "rate" "round" "stdev" "sum" "variance"))
(series_line aggregation: (identifier) @function.builtin)
(call function: (attribute object: (identifier) @module attribute: (identifier) @function.builtin) (#eq? @module "calendar") (#any-of? @function.builtin "date" "time"))
(call function: (attribute object: (identifier) @module attribute: (identifier) @function.builtin) (#eq? @module "distance") (#any-of? @function.builtin "chebyshev" "cosine" "euclidean" "great_circle" "hypotenuse" "manhattan"))
(call function: (attribute object: (identifier) @module attribute: (identifier) @function.builtin) (#eq? @module "math") (#any-of? @function.builtin "acos" "asin" "atan" "atan2" "ceil" "cos" "cosh" "degrees" "exp" "floor" "fma" "ln" "log10" "log2" "pow" "radians" "sign" "sin" "sinh" "sqrt" "tan" "tanh" "trunc"))

; the words grammar.js spells, by [LLEX.9.6]'s class
(null) @constant.builtin
(inf) @constant.builtin
(nan) @constant.builtin
["activated" "activation" "after" "alias" "all_time" "ambient" "as" "at" "base" "by" "cache_deleted" "cached" "called" "capacity" "const" "cooldown" "count" "default" "dimension" "emitted" "empty" "error" "explicit" "field" "for" "formula" "from" "from_base" "fx_pair" "gap" "has" "hold" "implicit" "import" "initial" "inputs" "inverting" "key" "kwarg" "label" "latest" "let" "literal" "logged" "logical" "mutable" "never" "no" "none" "on" "opaque" "over" "produces" "published" "required" "response" "responses" "retained" "retracted" "rule" "sample" "scalar" "schema" "scope" "series" "service" "skip" "sliding" "storage" "test" "then" "timeout" "to" "to_base" "tolerance" "ttl" "tumbling" "type" "unit" "until" "use" "via" "where" "within" "wm" "zero"] @keyword
["and" "contains" "in" "is" "not" "or" "overlaps"] @keyword.operator
["cache" "cache_delete" "call" "emit" "log" "publish" "withdraw"] @keyword.function
["false" "true"] @constant.builtin

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," "." ":"] @punctuation.delimiter
["!=" "!~" "%" "&" "*" "**" "+" "-" "->" ".." "/" "//" "::" "<" "<<" "<=" "=" "==" ">" ">=" ">>" "?" "??" "^" "|" "~"] @operator

%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% dsc -- the DS compiler: DS source to `.dsc` artefacts.
%
% `ds.dsc` and its siblings are the artefact's decoder; this is the encoder.
% `ds.token` means Rete tokens; `dsc.token` means lexical tokens.
%-----------------------------------------------------------------------------%

:- module dsc.
:- interface.

% -- The front end ------------------------------------------------------------

:- include_module token.     % the lexical token, and source positions
:- include_module layout.    % INDENT/DEDENT/NEWLINE -- a fold over the lines
:- include_module lex.       % bytes to tokens, grouped into lines
:- include_module unicode.   % GENERATED: the pinned Unicode 16.0 tables
:- include_module uniname.   % identifier legality, mixed script, NFC
:- include_module expr.      % the expression sublanguage, shared by both trees
:- include_module strlit.    % a string literal's escapes and sites, read once
:- include_module cst.       % the concrete syntax tree
:- include_module parse.     % tokens to CST, by recursive descent
:- include_module ast.       % the abstract syntax tree
:- include_module build.     % CST to AST -- one default, and no error arm

% -- Diagnostics --------------------------------------------------------------

:- include_module validate_codes. % GENERATED: the DS_VALIDATE_* registry
:- include_module diag.      % the diagnostic carrier, over that registry

% -- The middle ---------------------------------------------------------------

:- include_module builtins.  % the author-surface builtin function names
:- include_module builtin_fns. % GENERATED: [LEXP.17.2]'s builtin functions
:- include_module builtin_types. % GENERATED: [LGRA.22.8]'s builtin types
:- include_module reserved.  % GENERATED: [LLEX.9.6]'s reserved-word list
:- include_module json.      % JSON text to `ds.json`s term
:- include_module exact.     % exact rationals, rounded once to binary64
:- include_module cast.      % [LCST.4]'s conversion table, two closed sets
:- include_module types.     % the static type: leaf kind, dimension, nullability
:- include_module quantity.  % a quantity's exact value, in base and named units
:- include_module narrow.    % [LNUL.5.4] case (a): the two-shape flow typing
:- include_module series.    % the `series` declarations, and cursor resolution
:- include_module typecheck. % the expression-typing walk
:- include_module imports.   % resolving an `import` to a library's decls
:- include_module libcall.   % a `math` / `distance` member call, to its row
:- include_module yaml.      % the strict YAML subset a dialect file is written in
:- include_module capability. % [LCAP.1]'s registry, and a program's settings
:- include_module dialect.   % the registered dialects, and what `use` admits
:- include_module cycle.     % the rule dependency graph, and its cycles
:- include_module validate.  % everything schema-dependent and cross-declaration
:- include_module resolve.   % names: the file-scope tables and identity keys

% -- The back end -------------------------------------------------------------

:- include_module lower.     % the AST's schemas to the runtime's descriptors
:- include_module rete.      % the rules to the runtime's raw network nodes
:- include_module contract.  % a `.dsrt` realtime contract, read and hashed
:- include_module dstest.    % `test` declarations to the T* / O* atoms
:- include_module encode.    % schemas to `.dsc` atoms, over `ds.wire`s builder

% -- The composition ----------------------------------------------------------

:- include_module driver.    % source text to artefact bytes, phase by phase
:- include_module astjson.   % the syntax tree as `ds_ast` reads it, as JSON
:- include_module render.    % diagnostics as traceback-shaped text
:- include_module cli.       % the command line, as a predicate over its streams

%-----------------------------------------------------------------------------%
:- end_module dsc.
%-----------------------------------------------------------------------------%

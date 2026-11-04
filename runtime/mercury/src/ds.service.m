% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.service -- a service declaration's kwargs, as the ServiceDef atom carries
% them.
%
% `proto/service_def.proto`'s `ServiceKwarg`, one type for the compiler
% (`dsc.encode`) and the loader (`ds.dsc.service_kwargs`). Nothing in the engine
% reads it: a `default` is lowered into every call that omits the kwarg
% ([LADP.8.5.1]). It is a read for a host.
%-----------------------------------------------------------------------------%

:- module ds.service.
:- interface.

:- import_module bool.

:- type service_kwarg
    --->    service_kwarg(
                sk_name     :: string,
                            % field 2

                sk_type     :: string,
                            % Field 1, `ds_type`: a name as the declaration wrote it
                            % ([RDSC.6a.2.7]).

                sk_required :: bool,
                            % field 3 ([LADP.8.5.1])

                sk_literal  :: bool,
                            % field 4 ([LGRA.10.7])

                sk_default  :: kwarg_default
                            % fields 5 and 6
            ).

    % `has_default` (5) and `default_value` (6) as one value.
    %
:- type kwarg_default
    --->    no_default

    ;       default_text(string)
            % [RDSC.6a.2.4]: the canonical text of the value the service receives, in
            % the storage type of its declared type. Never empty. Not parsed here.

    ;       default_unstated.
            % `has_default` is true and `default_value` empty: a default whose unit
            % the compiling file could not see (`dsc.encode.rdsc_6a_2_4_text`).

%-----------------------------------------------------------------------------%
:- implementation.
%-----------------------------------------------------------------------------%

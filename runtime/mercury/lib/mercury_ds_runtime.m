%-----------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
% Mercury implementation of the DS runtime.
%
% mercury_ds_runtime.m -- the top module of the installable library.
%
% The runtime installs as the Mercury library `mercury_ds_runtime`, so a host
% links it with `--ml mercury_ds_runtime`, clear of `libds`, the C runtime's
% archive. Mercury names a library after the module `mmc --make lib<name>`
% starts from; this module imports `ds`, so every module `ds` includes is
% built and installed with it. A host imports `ds.*`.
%
% Built and installed by mercury.build's `mercury-lib-install`, in `hlc.gc`,
% into `.build/mercury/prefix/`. From a checkout (PORTING.md says what it
% needs):
%
%     python3 -m build_unit mercury.build \
%         .build/mercury/prefix/lib/mercury/lib/hlc.gc/libmercury_ds_runtime.a
%
% A host then builds with
% `--mld .build/mercury/prefix/lib/mercury --ml mercury_ds_runtime`, and
% statically adds `--library re2 --library stdc++`.
%-----------------------------------------------------------------------------%

:- module mercury_ds_runtime.
:- interface.

    % The DS version the library was built from: ds.version's, the one the
    % loader compares an artefact's against ([LDET.1.10]).
    %
:- func ds_version = string.

:- implementation.

:- import_module ds.
:- import_module ds.version.

ds_version = ds.version.ds_version.

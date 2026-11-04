% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.platform -- the platform signature ([LDET.2.3], [NDET.2]). Nothing in the
% engine reads it ([LDET.2.3.6]).
%
% A sanctioned foreign module: four fields are the C compiler's predefined macros,
% answered by the preprocessor tests of `runtime/src/libds/platform.c`, copied, as
% those are `static` there. The runtime differential's platform check holds the
% copy to libds.
% Each `promise_pure` answers a string fixed at compile time.
%-----------------------------------------------------------------------------%

:- module ds.platform.
:- interface.

:- import_module ds.series.
:- import_module list.

%-----------------------------------------------------------------------------%

:- type platform_signature
    --->    platform_signature(
                ps_os_family  :: string,
                            % [LDET.2.3.2]
                ps_cpu_arch   :: string,
                            % [LDET.2.3.3]
                ps_libc       :: string,
                            % [LDET.2.3.4]: musl defines no macro to tell it by,
                            % so it reads unknown.
                ps_compiler   :: string,
                            % [LDET.2.3.5]: the C compiler, not `mmc`.
                ps_ds_version :: string,
                            % [LDET.1.10]
                ps_backends   :: list(string)
                            % [NDET.2.2]: one per series backend, in slot order.
            ).

:- func platform_signature = platform_signature.

    % The series backends in slot order, the ring buffer last.
    %
:- func backend_slot_order = list(backing).

    % A backend's identity, `<atom>:<name>:<version>` (NDET.2.2), `<atom>` the body
    % message of the backing's atom in [RDSC.7.1]:
    % `SeriesBackendRingBuffer:ds-ring-buffer:1.0.0`.
    %
:- func backend_identity(backing) = string.

%-----------------------------------------------------------------------------%
:- implementation.

:- import_module ds.atom.
:- import_module ds.version.
:- import_module string.

%-----------------------------------------------------------------------------%

platform_signature = platform_signature(os_family, cpu_arch, libc, compiler,
    ds.version.ds_version, list.map(backend_identity, backend_slot_order)).

backend_slot_order = [bk_welford, bk_monotonic_deque, bk_fifo_deque,
    bk_reservoir, bk_interval_pulse, bk_numeric_integral, bk_ring_buffer].

backend_identity(B) = atom_message(A) ++ ":" ++ backend_name(B) :-
    atom_of_backing(B, A).

    % [NDET.2.5]'s table.
    %
:- func backend_name(backing) = string.

backend_name(bk_welford)          = "ds-welford-ewma:0.1.0".
backend_name(bk_monotonic_deque)  = "ds-monotonic-deque:0.1.0".
backend_name(bk_fifo_deque)       = "ds-fifo-deque:0.1.0".
backend_name(bk_reservoir)        = "ds-reservoir:0.1.0".
backend_name(bk_interval_pulse)   = "ds-interval-pulse:0.1.0".
backend_name(bk_numeric_integral) = "ds-numeric-integral:0.1.0".
backend_name(bk_ring_buffer)      = "ds-ring-buffer:1.0.0".

%-----------------------------------------------------------------------------%
% The four build facts
%-----------------------------------------------------------------------------%

:- func os_family = string.
:- func cpu_arch = string.
:- func libc = string.
:- func compiler = string.

    % `stdlib.h` brings glibc's `features.h`, and with it `__GLIBC__`, into scope.
    %
:- pragma foreign_decl("C", local, "
#include <stdlib.h>

#define DS_PLATFORM_STR_(x) #x
#define DS_PLATFORM_STR(x)  DS_PLATFORM_STR_(x)

static const char *
ds_platform_os_family(void)
{
#if defined(__linux__)
    return \"linux\";
#elif defined(__APPLE__) && defined(__MACH__)
    return \"macos\";
#elif defined(_WIN32) || defined(_WIN64)
    return \"windows\";
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \\
   || defined(__DragonFly__)
    return \"bsd\";
#else
    return \"unknown\";
#endif
}

static const char *
ds_platform_cpu_arch(void)
{
#if defined(__x86_64__) || defined(_M_X64)
    return \"x86_64\";
#elif defined(__aarch64__) || defined(_M_ARM64)
    return \"aarch64\";
#elif defined(__arm__) || defined(_M_ARM)
    return \"arm\";
#elif defined(__i386__) || defined(_M_IX86)
    return \"x86\";
#else
    return \"unknown\";
#endif
}

static const char *
ds_platform_libc(void)
{
#if defined(__GLIBC__)
    return \"glibc-\" DS_PLATFORM_STR(__GLIBC__) \".\"
                    DS_PLATFORM_STR(__GLIBC_MINOR__);
#elif defined(__APPLE__)
    return \"apple\";
#elif defined(_WIN32) || defined(_WIN64)
    return \"msvcrt\";
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    return \"bsd-libc\";
#else
    return \"unknown\";
#endif
}

static const char *
ds_platform_compiler(void)
{
#if defined(__clang__)
    return \"clang-\" DS_PLATFORM_STR(__clang_major__) \".\"
                     DS_PLATFORM_STR(__clang_minor__);
#elif defined(__GNUC__)
    return \"gcc-\" DS_PLATFORM_STR(__GNUC__) \".\"
                   DS_PLATFORM_STR(__GNUC_MINOR__);
#elif defined(_MSC_VER)
    return \"msvc-\" DS_PLATFORM_STR(_MSC_VER);
#else
    return \"unknown\";
#endif
}
").

:- pragma foreign_proc("C",
    os_family = (S::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    MR_make_aligned_string_copy(S, ds_platform_os_family());
").

:- pragma foreign_proc("C",
    cpu_arch = (S::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    MR_make_aligned_string_copy(S, ds_platform_cpu_arch());
").

:- pragma foreign_proc("C",
    libc = (S::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    MR_make_aligned_string_copy(S, ds_platform_libc());
").

:- pragma foreign_proc("C",
    compiler = (S::out),
    [will_not_call_mercury, promise_pure, thread_safe],
"
    MR_make_aligned_string_copy(S, ds_platform_compiler());
").

%-----------------------------------------------------------------------------%
:- end_module ds.platform.
%-----------------------------------------------------------------------------%

// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// ds_re2.cc — the C++ side of the C-callable RE2 shim. Its memory goes through
// C++'s global operator new, not the DS_* layer ([IALC.3.5]).
//
// No exception leaves this file ([IALC.3.6], [IERR.8.7]): unwinding out of an
// `extern "C"` function is undefined. The only exceptions raised here are allocation
// failures, so `catch (...)` reports them all as one.

#include "ds_re2.h"

#include <map>
#include <new>
#include <string>
#include <vector>

#include <re2/re2.h>

struct ds_re2 {
    RE2 re;
    ds_re2(const std::string &pattern, const RE2::Options &opts)
        : re(pattern, opts) {}
};

namespace {

// No printf ([IARC.1.16]).
void copy_err(char *err, size_t cap, const char *msg)
{
    size_t i = 0;
    for (; msg[i] != '\0' && i + 1 < cap; i++) err[i] = msg[i];
    err[i] = '\0';
}

void report_oom(char *err, size_t errcap)
{
    if (err != nullptr && errcap > 0) {
        copy_err(err, errcap, DS_RE2_ERR_OOM);
    }
}

} // namespace

extern "C" ds_re2_t *ds_re2_compile(const char *pattern,
                                    unsigned    flags,
                                    char       *err,
                                    size_t      errcap)
{
    if (pattern == nullptr) return nullptr;
    return ds_re2_compile_n(pattern, std::char_traits<char>::length(pattern),
                            flags, err, errcap);
}

extern "C" ds_re2_t *ds_re2_compile_n(const char *pattern,
                                      size_t      len,
                                      unsigned    flags,
                                      char       *err,
                                      size_t      errcap)
{
    if (pattern == nullptr) return nullptr;

    ds_re2_t *h = nullptr;
    try {
        RE2::Options opts;
        opts.set_log_errors(false);
        opts.set_case_sensitive((flags & DS_RE2_ICASE) == 0);
        opts.set_dot_nl((flags & DS_RE2_DOTALL) != 0);

        // `m` is `(?m)`, not `one_line`, which RE2 consults only under
        // posix_syntax. A flag group is no capture, so group numbering holds.
        std::string source;
        if (flags & DS_RE2_MULTILINE) source += "(?m)";
        source.append(pattern, len);

        h = new ds_re2(source, opts);

        if (!h->re.ok()) {
            if (err != nullptr && errcap > 0) {
                const std::string &e = h->re.error();
                copy_err(err, errcap, e.c_str());
            }
            delete h;
            return nullptr;
        }
        return h;
    } catch (...) {
        delete h;
        report_oom(err, errcap);
        return nullptr;
    }
}

extern "C" bool ds_re2_match(const ds_re2_t *re, const char *text, bool *oom)
{
    if (oom != nullptr) *oom = false;
    if (re == nullptr || text == nullptr) return false;
    try {
        return RE2::PartialMatch(text, re->re);
    } catch (...) {
        if (oom != nullptr) *oom = true;
        return false;
    }
}

extern "C" bool ds_re2_match_n(const ds_re2_t *re, const char *text, size_t len,
                               bool *oom)
{
    if (oom != nullptr) *oom = false;
    if (re == nullptr || text == nullptr) return false;
    try {
        return RE2::PartialMatch(re2::StringPiece(text, len), re->re);
    } catch (...) {
        if (oom != nullptr) *oom = true;
        return false;
    }
}

extern "C" int ds_re2_group_count(const ds_re2_t *re)
{
    if (re == nullptr) return 0;
    return re->re.NumberOfCapturingGroups();
}

extern "C" const char *ds_re2_group_name(const ds_re2_t *re, int index)
{
    if (re == nullptr || index < 1) return nullptr;
    try {
        // RE2 builds the map on its first call: a failure there is "no name".
        const std::map<int, std::string> &names = re->re.CapturingGroupNames();
        const auto it = names.find(index);
        return it == names.end() ? nullptr : it->second.c_str();
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool ds_re2_capture(const ds_re2_t  *re,
                               const char      *text,
                               const char     **out_ptr,
                               size_t          *out_len,
                               int              n_out,
                               bool            *oom)
{
    if (oom != nullptr) *oom = false;
    if (text == nullptr) return false;
    return ds_re2_capture_n(re, text, std::char_traits<char>::length(text),
                            out_ptr, out_len, n_out, oom);
}

extern "C" bool ds_re2_capture_n(const ds_re2_t  *re,
                                 const char      *text,
                                 size_t           len,
                                 const char     **out_ptr,
                                 size_t          *out_len,
                                 int              n_out,
                                 bool            *oom)
{
    if (oom != nullptr) *oom = false;
    if (re == nullptr || text == nullptr || n_out < 0) return false;
    if (n_out > 0 && (out_ptr == nullptr || out_len == nullptr)) return false;

    try {
        // Match() fills group 0, the whole match, in slot 0.
        const int nsub = n_out + 1;
        std::vector<re2::StringPiece> sub(static_cast<size_t>(nsub));

        const re2::StringPiece input(text, len);
        // Unanchored, as ds_re2_match's PartialMatch: the gate and the extraction
        // must agree about which strings match.
        if (!re->re.Match(input, 0, input.size(), RE2::UNANCHORED,
                          sub.data(), nsub)) {
            return false;
        }

        for (int i = 0; i < n_out; i++) {
            const re2::StringPiece &g = sub[static_cast<size_t>(i) + 1];
            if (g.data() == nullptr) {
                out_ptr[i] = nullptr;
                out_len[i] = 0;
            } else {
                out_ptr[i] = g.data();
                out_len[i] = g.size();
            }
        }
        return true;
    } catch (...) {
        if (oom != nullptr) *oom = true;
        return false;
    }
}

extern "C" void ds_re2_free(ds_re2_t *re)
{
    delete re;
}

extern "C" bool ds_re2_available(void)
{
    return true;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * date_range.h — the Date range ([LTIM.1.2.2]): the days whose midnight in UTC is a
 * representable Time, 1677-09-22 (-106751) through 2262-04-11 (106751).
 */
#ifndef LIBDS2_INTERNAL_DATE_RANGE_H
#define LIBDS2_INTERNAL_DATE_RANGE_H

#include <stdbool.h>
#include <stdint.h>

#define DS_DATE_DAYS_MIN (-INT64_C(106751))
#define DS_DATE_DAYS_MAX INT64_C(106751)

static inline bool ds_date_days_in_range(int64_t days)
{
    return days >= DS_DATE_DAYS_MIN && days <= DS_DATE_DAYS_MAX;
}

#endif /* LIBDS2_INTERNAL_DATE_RANGE_H */

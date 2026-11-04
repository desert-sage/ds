/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * planted_unknown_helper.c -- the negative fixture of part 2's classification
 * ([NDET.1.4]).
 *
 * An object that calls a helper nothing defines and no table names. The
 * driver derives the helper set over the row's libds.a and this object
 * together, on every run, and fails unless the classification refuses
 * `ds_testfloat_planted_unknown_helper` by name: a classification that let an
 * unknown symbol through would let the next helper a toolchain adds through
 * untested. It is compiled, never linked.
 */
double ds_testfloat_planted_unknown_helper(double x);

double ds_testfloat_planted_caller(double x)
{
    return ds_testfloat_planted_unknown_helper(x);
}

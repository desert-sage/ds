/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * dsc/ds_pb_alloc.h — the protobuf-c allocator that routes unpack / free_unpacked
 * through libds's DS_* layer ([IALC.3.1]), and the judge of a body before it is
 * unpacked.
 */
#ifndef LIBDS2_INTERNAL_DSC_DS_PB_ALLOC_H
#define LIBDS2_INTERNAL_DSC_DS_PB_ALLOC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <protobuf-c/protobuf-c.h>

/* Not `const`: protobuf-c's entry points take a non-const allocator. */
extern ProtobufCAllocator ds_pb_allocator;

/*
 * [RDSC.11.4]: a body judged, read as `desc`, before protobuf-c unpacks it.
 * Allocates nothing, and the first defect met answers.
 *
 *   DS_PB_JUDGE_UNDECODABLE  the bytes do not frame, or a field arrives in a wire
 *                            type protobuf-c's unpack refuses for it;
 *   DS_PB_JUDGE_REPEATED     a message field that is not repeated occurs more than
 *                            once ([RDSC.9.5]);
 *   DS_PB_JUDGE_BAD_STRING   a `string` field holds ill-formed UTF-8 or a 0x00 byte
 *                            ([RDSC.9.12]);
 *   DS_PB_JUDGE_TOO_DEEP     a `nested` message lies deeper than `limit`
 *                            ([RDSC.11.3]). It is not read, so the walk recurses no
 *                            deeper ([RDSC.9.9]). NULL `nested` counts none.
 */
typedef enum {
    DS_PB_JUDGE_DECODES = 0,
    DS_PB_JUDGE_UNDECODABLE,
    DS_PB_JUDGE_REPEATED,
    DS_PB_JUDGE_BAD_STRING,
    DS_PB_JUDGE_TOO_DEEP,
} ds_pb_judge_t;

ds_pb_judge_t ds_pb_rdsc_11_4_judge(const ProtobufCMessageDescriptor *desc,
                                    const ProtobufCMessageDescriptor *nested,
                                    unsigned limit,
                                    const uint8_t *body, size_t len);

/*
 * [RDSC.9.5]: the judge with no depth bound, true when it answers
 * DS_PB_JUDGE_REPEATED. Every loader that calls protobuf-c's `unpack` on an
 * artefact's body asks this, or the judge, first.
 */
bool ds_pb_rdsc_9_5_repeats(const ProtobufCMessageDescriptor *desc,
                            const uint8_t *body, size_t len);

#endif /* LIBDS2_INTERNAL_DSC_DS_PB_ALLOC_H */

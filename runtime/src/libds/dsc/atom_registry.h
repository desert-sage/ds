/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * GENERATED — do not edit; regenerate it. A drift check fails if this
 * file and its sources have drifted apart.
 *
 * The atom registry, for the runtime reader.
 * Sources: proto/atom.proto (number <-> message, [RFCS.16.1]),
 * [RFCS.3.1] (stream-legal), [RDSC.7.1] (DSC-legal),
 * [RFCS.3.4] (replay class).
 *
 * An entry carries no name. The field number is the whole of an atom's
 * wire identity ([RFCS.16.1]) and every consumer holds it; what a reader
 * shows a person is `message`. The per-atom numbers are rfcs/atoms.h's,
 * which ships beside rfcs/rfcs.h.
 */
#ifndef DS_DSC_ATOM_REGISTRY_H
#define DS_DSC_ATOM_REGISTRY_H

#include <stddef.h>
#include <stdint.h>

#include "../rfcs/atoms.h"

/* [RFCS.17.1] container-legality. A bitmask: an atom may be legal in both. */
#define DS_ATOM_LEGAL_DSC     0x1u
#define DS_ATOM_LEGAL_STREAM  0x2u
#define DS_ATOM_LEGAL_BOTH    (DS_ATOM_LEGAL_DSC | DS_ATOM_LEGAL_STREAM)

/* [RFCS.3.4] replay class. NONE == the atom is not stream-legal, so it
 * has no replay role to have. */
typedef enum {
    DS_ATOM_CLASS_NONE       = 0,
    DS_ATOM_CLASS_INJECT     = 1,
    DS_ATOM_CLASS_COMPARE    = 2,
    DS_ATOM_CLASS_STRUCTURAL = 3
} ds_atom_class_t;

typedef struct {
    uint16_t number;      /* the oneof field number — the wire identity */
    uint8_t  legality;    /* DS_ATOM_LEGAL_* bitmask */
    uint8_t  klass;       /* ds_atom_class_t */
    const char *message;  /* the proto message the body parses as, e.g.
                             "FactAssert": what a reader shows a person */
} ds_atom_reg_entry_t;

#define DS_ATOM_REGISTRY_COUNT 61

/* Ascending by number: `ds_pbf_lookup` binary-searches it. */
extern const ds_atom_reg_entry_t ds_atom_registry[DS_ATOM_REGISTRY_COUNT];

#endif /* DS_DSC_ATOM_REGISTRY_H */

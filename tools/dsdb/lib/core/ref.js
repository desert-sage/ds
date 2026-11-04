// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// A fact-ref slot's value as a recording holds it. libds decodes the
// slot to its recorded handle, and [RFCS.6.3] makes that handle the fact_id of
// the earlier record in the same stream that carried the referenced fact. So
// the value is that fact, named as dsdb names a fact everywhere: its schema
// and its id, `Motion#2`. It names nothing outside its recording ([RFCS.4]).
//
// Not a @ds-lang/ds Fact: no engine holds it. Where a slot is shown it reads as
// `Motion#2`; facts-out.js writes a reference by its `id`, as for a Fact.

export class RecordedRef {
    /**
     * @param {string} schema  the schema the slot names (Slot.schema_ref)
     * @param {bigint} id  the recorded handle: the referenced fact's fact_id
     */
    constructor(schema, id) {
        /** @readonly */
        this.schema = schema;
        /** @readonly */
        this.id = id;
        Object.freeze(this);
    }

    toString() {
        return `${this.schema}#${this.id}`;
    }

    /** JSON: as it reads, `Motion#2`. */
    toJSON() {
        return this.toString();
    }
}

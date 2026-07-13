// Frozen behavior tests — column-config, the type MODEL + automatic alignment
// (planner-owned). ARCH-column-config criterion 16 (alignment) + the Swift/ABI
// value-type mapping. Pure, no GUI, no core: `ColumnAligning` is a value
// transform (like `WindowPolling`), and the enum raw values are pinned to the C
// ABI so the `CoreDocumentSession` bridge is a direct `rawValue` map.
//
// RED SEED: `ColumnAlignmentRules` left-aligns everything (pre-feature default),
// so the boolean-center / numeric-trailing assertions fail; the header-leading
// and ABI-mapping guards pass by construction.
import Testing
import Contracts
import LessSheetKit

@Suite("column-config type model + alignment")
struct ColumnMetadataModelTests {

    @Test func alignmentConformancePin() {
        let _: any ColumnAligning = ColumnAlignmentRules()
    }

    // AC16 — the FIXED automatic-alignment rule. RED on the boolean/numeric/
    // date/datetime cases (seed left-aligns them); header + text/unknown are
    // green guards.
    @Test func automaticAlignmentIsFixedByKind() {
        let a = ColumnAlignmentRules()
        // left: text / unknown / unsupported (guards — already leading).
        #expect(a.alignment(for: .text, isConflict: false) == .leading)
        #expect(a.alignment(for: .unknown, isConflict: false) == .leading)
        #expect(a.alignment(for: .unsupported, isConflict: false) == .leading)
        // center: boolean (RED).
        #expect(a.alignment(for: .boolean, isConflict: false) == .center)
        // right: integer / decimal / date / datetime (RED).
        #expect(a.alignment(for: .integer, isConflict: false) == .trailing)
        #expect(a.alignment(for: .decimal, isConflict: false) == .trailing)
        #expect(a.alignment(for: .date, isConflict: false) == .trailing)
        #expect(a.alignment(for: .datetime, isConflict: false) == .trailing)
        // headers are always leading (guard).
        #expect(a.headerAlignment == .leading)
    }

    // AC16 — a CONFLICT cell keeps its column's alignment: `isConflict` never
    // changes the result. RED on integer (seed leads; a correct impl trails
    // whether or not the cell conflicts).
    @Test func conflictCellKeepsColumnAlignment() {
        let a = ColumnAlignmentRules()
        #expect(a.alignment(for: .integer, isConflict: true) == a.alignment(for: .integer, isConflict: false))
        #expect(a.alignment(for: .integer, isConflict: true) == .trailing)   // RED
    }

    // The Swift enum raw values match the C ABI enum values exactly, so the
    // bridge maps `ls_column_*` uint32 fields straight through `rawValue`
    // (guard against silent drift from the frozen api/lesssheet.h).
    @Test func enumRawValuesMatchTheABI() {
        #expect(ColumnKind.unknown.rawValue == 0)
        #expect(ColumnKind.text.rawValue == 2)
        #expect(ColumnKind.integer.rawValue == 4)
        #expect(ColumnKind.datetime.rawValue == 7)
        #expect(ColumnTypeSource.override.rawValue == 3)
        #expect(ColumnDatetimeSemantics.zoned.rawValue == 2)
        #expect(ColumnInferenceState.published.rawValue == 4)
        #expect(ColumnConfidence.exhaustive.rawValue == 3)
        #expect(ColumnNullPolicy.sentinel.rawValue == 1)
        #expect(ColumnConflictState.proposed.rawValue == 2)
        // The default descriptor is unknown with all-unspecified parameters.
        #expect(ColumnType.unknown.kind == .unknown)
        #expect(ColumnType.unknown.decimalPrecision == nil)
        #expect(ColumnType.unknown.datetimeSemantics == .none)
    }
}

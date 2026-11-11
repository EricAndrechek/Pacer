import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The table's saved layout is decoded once and written back only on a change
// (#400). The hosted tests in `UsageTableLayoutTests` cover the table around
// it; these cover the load/save type on its own.

@MainActor
@Suite("Usage column layout box")
struct UsageColumnLayoutBoxTests {
    typealias Row = PacerUsageRow<PacerUsageNoExtra>
    typealias Box = UsageColumnLayoutBox<Row>

    private static func store() -> (UserDefaults, String) {
        let name = "pacer.tests.layoutBox.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("nothing stored is the default layout")
    func empty() {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let layout = Box().value(tableId: "t", store: store)
        #expect(layout[visibility: UsageColumn.input.rawValue] == .automatic)
    }

    @Test("a layout from an older build loads, under the same key")
    func oldFormatLoads() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.set(Data(UsageTableLayoutTests.round1Layout.utf8),
                  forKey: PacerUsageTableMetrics.columnsKey(tableId: "t"))
        let layout = Box().value(tableId: "t", store: store)
        #expect(layout[visibility: UsageColumn.input.rawValue] == .hidden)
    }

    @Test("a write persists and a new box reads it back; the first box does not re-read defaults")
    func roundTrip() {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let box = Box()
        var layout = box.value(tableId: "t", store: store)
        layout[visibility: UsageColumn.cacheRead.rawValue] = .visible
        box.set(layout, tableId: "t", store: store)
        #expect(Box().value(tableId: "t", store: store)[visibility: UsageColumn.cacheRead.rawValue] == .visible)

        // Cached: a change made behind its back is not seen.
        store.removeObject(forKey: PacerUsageTableMetrics.columnsKey(tableId: "t"))
        #expect(box.value(tableId: "t", store: store)[visibility: UsageColumn.cacheRead.rawValue] == .visible)
    }

    @Test("reset stores the default layout; tables keep separate keys")
    func reset() {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let box = Box()
        var layout = box.value(tableId: "a", store: store)
        layout[visibility: UsageColumn.cacheRead.rawValue] = .visible
        box.set(layout, tableId: "a", store: store)
        box.set(TableColumnCustomization<Row>(), tableId: "a", store: store)
        #expect(Box().value(tableId: "a", store: store)[visibility: UsageColumn.cacheRead.rawValue] == .automatic)
        #expect(Box().value(tableId: "b", store: store)[visibility: UsageColumn.cacheRead.rawValue] == .automatic)
    }

    @Test("an undecodable stored value is the default layout")
    func garbage() {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.set(Data("nope".utf8), forKey: PacerUsageTableMetrics.columnsKey(tableId: "t"))
        #expect(Box().value(tableId: "t", store: store)[visibility: UsageColumn.input.rawValue] == .automatic)
    }
}

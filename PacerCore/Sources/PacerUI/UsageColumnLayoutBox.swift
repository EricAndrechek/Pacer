import SwiftUI

/// A table's saved column layout, decoded once.
///
/// `@AppStorage<TableColumnCustomization>` decodes the stored JSON every time
/// the view's body reads it, and `PacerUsageTable`'s body runs on every
/// redraw of Models, History, Projects and the detail sheets: Sentry PACER-11
/// caught that decode holding the main thread for over two seconds inside a
/// layout pass (#400). This reads defaults and decodes on the first read, then
/// answers from memory; only a change the user makes is written back.
///
/// It is a plain class held in `@State` for its identity. The view reads
/// `revision` (a `@State` it bumps after every `set`) in its own body, so a
/// write redraws it; the box itself is a cache nothing displays.
@MainActor
final class UsageColumnLayoutBox<Row: Identifiable> {
    private var cached: TableColumnCustomization<Row>?

    init() {}

    /// The stored layout, from defaults on the first call. The key and format
    /// are the ones `AppStorage` used, so layouts saved by older builds load.
    func value(tableId: String, store: UserDefaults) -> TableColumnCustomization<Row> {
        if let cached { return cached }
        PacerUsageTableMetrics.applyLayoutDefaults(tableId: tableId, store: store)
        PacerUsageTableMetrics.migrateLayout(tableId: tableId, store: store)
        let loaded = Self.load(tableId: tableId, store: store)
        cached = loaded
        return loaded
    }

    /// Remembers `layout` and writes it to defaults.
    func set(_ layout: TableColumnCustomization<Row>, tableId: String, store: UserDefaults) {
        cached = layout
        Self.save(layout, tableId: tableId, store: store)
    }

    /// A missing or undecodable value is the default layout, as it was under
    /// `AppStorage`.
    nonisolated static func load(tableId: String, store: UserDefaults) -> TableColumnCustomization<Row> {
        guard let data = store.data(forKey: PacerUsageTableMetrics.columnsKey(tableId: tableId)),
              let layout = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data)
        else { return TableColumnCustomization<Row>() }
        return layout
    }

    nonisolated static func save(_ layout: TableColumnCustomization<Row>, tableId: String,
                                 store: UserDefaults) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        store.set(data, forKey: PacerUsageTableMetrics.columnsKey(tableId: tableId))
    }
}

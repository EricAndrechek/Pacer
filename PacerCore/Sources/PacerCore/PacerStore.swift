import Foundation
import SwiftData

public enum PacerStoreError: Error, Sendable {
    case appGroupContainerUnavailable(identifier: String)
}

public enum PacerStore {
    public static let appGroupIdentifier = "group.com.ericandrechek.pacer"
    public static let storeFileName = "pacer.sqlite"

    public static func sharedContainerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw PacerStoreError.appGroupContainerUnavailable(identifier: appGroupIdentifier)
        }
        return url
    }

    public static func storeURL() throws -> URL {
        try sharedContainerURL().appendingPathComponent(storeFileName)
    }

    public static func makeModelContainer() throws -> ModelContainer {
        let url = try storeURL()
        let configuration = ModelConfiguration(url: url)
        return try ModelContainer(for: Heartbeat.self, configurations: configuration)
    }
}

import Foundation
import SwiftData
import PacerCore

@MainActor
func runDaemonLoop() async throws {
    let container = try PacerStore.makeModelContainer()
    let context = ModelContext(container)
    let storeURL = try PacerStore.storeURL()

    print("[PacerDaemon] starting; SwiftData container at \(storeURL.path)")

    while !Task.isCancelled {
        context.insert(Heartbeat(source: "daemon"))
        try context.save()

        let descriptor = FetchDescriptor<Heartbeat>()
        let count = try context.fetchCount(descriptor)
        print("[PacerDaemon] heartbeat written; total rows = \(count)")

        try await Task.sleep(for: .seconds(10))
    }
}

@main
struct PacerDaemonMain {
    static func main() async {
        do {
            try await runDaemonLoop()
        } catch {
            FileHandle.standardError.write(Data("[PacerDaemon] fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}

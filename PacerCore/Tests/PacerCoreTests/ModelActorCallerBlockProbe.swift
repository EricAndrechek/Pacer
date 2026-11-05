import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Does awaiting a busy `@ModelActor` from the main actor hold the main
/// thread, or suspend it? Measured, not assumed: a heartbeat on the main
/// actor records its longest gap while the main actor awaits a trivial call
/// on an actor that is busy for two seconds.
@Suite("ModelActor caller block probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_MODELACTOR_PROBE"] != nil))
struct ModelActorCallerBlockProbe {

    @ModelActor
    actor Busy {
        func spin(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            var x = 0.0
            while Date() < end { x += sin(x) }
            _ = x
        }
        func trivial() -> Int { 1 }
    }

    @MainActor
    final class Beat {
        var longest = 0.0
        var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor in
                var last = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = Date()
                    self.longest = max(self.longest, now.timeIntervalSince(last) - 0.005)
                    last = now
                }
            }
        }
    }

    @MainActor
    @Test func mainActorAwaitingABusyModelActor() async throws {
        let container = try ModelContainer(
            for: ClaudeCodeMeta.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let busy = await Task.detached { Busy(modelContainer: container) }.value
        let beat = Beat()
        beat.start()
        try await Task.sleep(for: .milliseconds(100))
        let spinning = Task.detached { await busy.spin(2) }
        try await Task.sleep(for: .milliseconds(200))
        let began = Date()
        _ = await busy.trivial()
        let waited = Date().timeIntervalSince(began)
        await spinning.value
        try await Task.sleep(for: .milliseconds(100))
        beat.task?.cancel()
        print(String(format: "[modelactor] main awaited %.0f ms; main heartbeat's longest gap %.0f ms",
                     waited * 1000, beat.longest * 1000))
    }
}

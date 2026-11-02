import Testing
@testable import PacerCore

@Suite("Scoped window telemetry kind")
struct WindowTelemetryKindTests {

    private func scoped(group: String, id: String? = nil, name: String? = nil, surface: String? = nil) -> WindowSpec {
        WindowSpec.scoped(identity: "\(group)|\(id ?? "")|\(surface ?? "")", group: group, label: name ?? "",
                          modelId: id, modelDisplayName: name, surface: surface)
    }

    @Test("a model family and a cadence, no version")
    func family() {
        #expect(scoped(group: "weekly", name: "Opus 4.7").telemetryKind == "weekly_opus")
        #expect(scoped(group: "Weekly", id: "claude-fable-5-1").telemetryKind == "weekly_fable")
        #expect(scoped(group: "session", name: "Sonnet").telemetryKind == "session_sonnet")
    }

    @Test("falls back to the surface, then to other, and stays identifier-safe")
    func fallbacks() {
        #expect(scoped(group: "weekly", surface: "cowork").telemetryKind == "weekly_cowork")
        #expect(scoped(group: "weekly").telemetryKind == "weekly_other")
        #expect(scoped(group: "we ekly/../x", name: "Op/us").telemetryKind == "we_op")
    }

    @Test("fixed windows have none")
    func fixed() {
        #expect(WindowSpec.fixed(.fiveHour).telemetryKind == nil)
    }
}

import AppKit
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// #245: the shared account row names an account's other clients. Measured
// off-screen, an `NSHostingView` never put in a window.

@MainActor
@Suite("Account row clients")
struct AccountRowClientsTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func size(_ model: PacerAccountRow<EmptyView>.Model) -> CGSize {
        NSHostingView(rootView: PacerAccountRow(model: model).frame(width: 560)).fittingSize
    }

    @Test("no clients is the row it always was; chips sit on the name line")
    func layout() {
        let plain = size(.init(name: "work", plan: "Max 20×", subtitle: "org …0001 · 1 token",
                               fiveHourPercent: 32, sevenDayPercent: 62, isActive: true))
        let empty = size(.init(name: "work", plan: "Max 20×", subtitle: "org …0001 · 1 token",
                               fiveHourPercent: 32, sevenDayPercent: 62, isActive: true, clients: []))
        let chipped = size(.init(name: "work", plan: "Max 20×", subtitle: "org …0001 · 1 token",
                                 fiveHourPercent: 32, sevenDayPercent: 62, isActive: true,
                                 clients: [PacerClientChip(id: "d", label: "Desktop", help: "")]))
        #expect(plain == empty)
        // A chip adds no line, and no height: Desktop starting or timing out
        // does not move the rows below.
        #expect(abs(chipped.height - plain.height) < 1)
    }

    @Test("the CLI never gets a chip: each screen marks it already")
    func cliOmitted() {
        let clients = AccountClients.build(
            cliAccount: "a", cliSince: t0, desktop: ["/d/Claude": ["a": t0]],
            installLabels: ["/d/Claude": "Desktop"],
            profiles: ["/p/1-work": "a"], profileActivity: ["/p/1-work": t0])
        let chips = PacerClientChip.others(clients.active(on: "a", at: t0))
        #expect(chips.map(\.label) == ["Desktop", "Profile · 1-work"])
        #expect(chips.first?.help.contains("30 minutes") == true)
    }
}

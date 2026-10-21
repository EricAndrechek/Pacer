import AppKit
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// #161: the sessions table is one container at every length, hugging short
// lists and capping long ones. Measured off-screen: an `NSHostingView` that is
// never put in a window.

@MainActor
@Suite("Sessions table sizing")
struct SessionsTableLayoutTests {

    private func rows(_ n: Int) -> [SessionRow] {
        (0..<n).map { i in
            SessionRow(sessionId: String(format: "session-%03d", i),
                       firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
                       lastSeenAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(i)),
                       projectPath: "/tmp/acme", ccVersion: nil, cumulativeCostUSD: 1,
                       cumulativeInputTokens: 1, cumulativeOutputTokens: 1,
                       cumulativeCacheReadTokens: 0, cumulativeCacheCreation5mTokens: 0,
                       cumulativeCacheCreation1hTokens: 0, topModel: "claude-opus-4-7")
        }
    }

    private func height(_ n: Int) -> CGFloat {
        let table = SessionsTable(rows: rows(n), showProjectColumn: false,
                                  sort: .constant(.lastSeen), sortDescending: .constant(true),
                                  onSessionTap: { _ in })
            .frame(width: 640)
        return NSHostingView(rootView: table).fittingSize.height
    }

    @Test("short lists hug their rows; long ones stop at the cap")
    func hugsThenCaps() {
        let three = height(3), ten = height(10), forty = height(40), hundred = height(100)
        #expect(three < ten)
        #expect(forty == hundred)
        #expect(forty > ten)
        // Header and divider above the capped rows.
        #expect(forty <= SessionsTable.scrollMaxHeight + 60)
    }
}

import SwiftUI
import PacerCore

/// One client active on an account (#245): a Desktop install, a pinned
/// profile. A plain value so any screen can hold one; build it from an
/// `AccountClients.Entry` with `init(_:)`.
public struct PacerClientChip: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let help: String

    public init(id: String, label: String, help: String) {
        self.id = id
        self.label = label
        self.help = help
    }

    public init(_ entry: AccountClients.Entry) {
        self.id = entry.clientId
        self.label = entry.label
        switch entry.kind {
        case .cli:
            self.help = "Claude Code in the terminal is signed into this account."
        case .desktop:
            self.help = "\(entry.label) ran a session on this account in the last 30 minutes."
        case .profile:
            self.help = "This profile wrote a turn on this account in the last 30 minutes."
        }
    }

    /// The chips a screen shows for an account: every active client except
    /// the CLI, which each screen already marks its own way ("signed in",
    /// "Active"), so it is not said twice.
    public static func others(_ entries: [AccountClients.Entry]) -> [PacerClientChip] {
        entries.filter { $0.kind != .cli }.map(PacerClientChip.init)
    }
}

/// The clients active on an account, as compact chips. Renders nothing when
/// there are none, so a screen can always place it.
public struct PacerClientChips: View {
    public let chips: [PacerClientChip]

    public init(_ chips: [PacerClientChip]) { self.chips = chips }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(chips) { chip in
                Chip(text: chip.label, tint: .green, size: .compact)
                    .help(chip.help)
            }
        }
    }
}

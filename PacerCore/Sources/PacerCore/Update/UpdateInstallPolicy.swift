import Foundation

/// When Pacer may relaunch itself to install an update Sparkle has already
/// downloaded and prepared.
///
/// Why this exists: with automatic updates on, Sparkle installs a downloaded
/// update when the app quits. Pacer is a menu-bar agent that runs for weeks
/// without quitting, so the update waited, and while it waited Sparkle checked
/// the feed once a week instead of every six hours, and every check, the
/// user's own included, resumed that waiting update rather than reading the
/// feed. A Mac sat on 0.8.0 for two days after 0.8.2 shipped, and its manual
/// check offered 0.8.1. The app now takes the install over (Sparkle's
/// `willInstallUpdateOnQuit` hand-off) and asks this rule when to do it.
///
/// The rule, apart from AppKit, so it can be tested. `UpdateInstallScheduler`
/// in the app target reads the Mac and acts on the answer.
///
/// What it guards against is someone noticing. A relaunch with no window open
/// shows nothing but the menu-bar item blinking; one with the dashboard open
/// puts the dashboard back where it was, but someone may be reading it, so that
/// waits for nobody to be at the Mac. Three things are never interrupted
/// however long the update has waited: an open menu, a store that is still
/// migrating, and text being edited (a relaunch would lose it). Pacer in use
/// and a second window block too, but only while someone is at the Mac, and
/// only for `ceiling`.
///
/// Why those two give way: while an update is held Sparkle runs no check at
/// all, so a hold that never ends is a Mac that silently stops updating. Being
/// the active app is not the same as being used: Pacer stays active when the
/// person in front of it walks away, and an About or Settings window can stay
/// open for weeks. Both used to block for ever, ahead of `maxWait`.
public enum UpdateInstallPolicy {

    /// What the rule reads. Durations, so the rule has no clock of its own.
    public struct Signals: Sendable, Equatable {
        /// Since Sparkle handed the prepared update over.
        public var sinceReady: TimeInterval
        /// Since Pacer last stopped being the active app, or since it launched
        /// if that is later. A Pacer that has just relaunched counts as just
        /// used, so two updates in a row never relaunch it back to back.
        public var sinceUsed: TimeInterval
        /// Since the last keyboard, mouse or trackpad input anywhere on the Mac.
        public var userIdle: TimeInterval
        /// Pacer is the active app.
        public var pacerActive: Bool
        /// One of Pacer's menus is open.
        public var menuOpen: Bool
        /// A window other than the dashboard, a sheet, or a modal panel is up.
        public var otherWindowOpen: Bool
        /// Something holds text a relaunch would lose: some window's first
        /// responder is a text field someone has changed since it took focus
        /// (`isEditing(_:)`; Settings is a tab of the dashboard, so its fields
        /// are not a second window), or a sheet or modal panel is up, whose
        /// contents the app cannot inspect. A field that merely has focus does
        /// not count: the dashboard can stay open on a monitor for weeks with
        /// the Projects search focused, and that must not hold an update for ever.
        public var editingText: Bool
        /// The dashboard is open, minimised, or behind a hidden Pacer: a
        /// relaunch brings it back on screen.
        public var dashboardOpen: Bool
        /// The store is still opening (a migration, the first launch after a
        /// schema change).
        public var storeOpening: Bool

        public init(sinceReady: TimeInterval, sinceUsed: TimeInterval, userIdle: TimeInterval,
                    pacerActive: Bool, menuOpen: Bool, otherWindowOpen: Bool,
                    editingText: Bool, dashboardOpen: Bool, storeOpening: Bool) {
            self.sinceReady = sinceReady; self.sinceUsed = sinceUsed; self.userIdle = userIdle
            self.pacerActive = pacerActive; self.menuOpen = menuOpen; self.otherWindowOpen = otherWindowOpen
            self.editingText = editingText
            self.dashboardOpen = dashboardOpen; self.storeOpening = storeOpening
        }
    }

    public enum Decision: Sendable, Equatable {
        case install(InstallReason)
        case wait(WaitReason)
    }

    public enum InstallReason: String, Sendable, Equatable {
        /// No window to bring back: nothing on screen changes.
        case noWindow = "no window"
        /// The dashboard is open but nobody is at the Mac.
        case userAway = "user away"
        /// The dashboard has stayed open with someone at the Mac for a day.
        case overdue
        /// Held for `ceiling` behind a window or an active Pacer, and nobody
        /// is at the Mac now.
        case heldTooLong = "held too long"
    }

    public enum WaitReason: String, Sendable, Equatable {
        case storeOpening = "store opening"
        case menuOpen = "menu open"
        case editingText = "editing text"
        case inUse = "in use"
        case windowOpen = "window open"
        case recentlyUsed = "recently used"
        case dashboardOpen = "dashboard open"
    }

    /// Pacer has to have been left alone this long.
    public static let quietAfterUse: TimeInterval = 10 * 60
    /// With the dashboard open, nobody has to have touched the Mac this long.
    public static let userAwayAfter: TimeInterval = 10 * 60
    /// With the dashboard open and someone always at the Mac, install anyway
    /// after this. While an update waits, Sparkle runs no check at all, so this
    /// bounds how far behind the feed a waiting update can fall. A Mac that is
    /// left alone for ten minutes in a day never reaches it.
    public static let maxWait: TimeInterval = 24 * 3600
    /// After this, only an open menu, a migrating store or text being edited keeps a held update
    /// from installing, once nobody has touched the Mac for `userAwayAfter`:
    /// not Pacer being active, not a forgotten second window, not the quiet
    /// period. Three days, so it only ever catches a hold the rules above
    /// would otherwise keep for ever.
    public static let ceiling: TimeInterval = 72 * 3600

    /// What the app can read from a window's first responder when it is text.
    public struct FocusedText: Sendable, Equatable {
        /// Typing would change it (a selectable label's field editor is not).
        public var editable: Bool
        /// It records its edits for undo. Without that, `canUndo` says nothing.
        public var allowsUndo: Bool
        /// Its undo manager holds an edit: something was typed, pasted or
        /// deleted since the field took focus.
        public var canUndo: Bool
        /// An input-method composition is in progress (Japanese, Chinese,
        /// Korean, dead keys): typed, not yet committed, and not on the undo
        /// stack yet.
        public var hasMarkedText: Bool

        public init(editable: Bool, allowsUndo: Bool, canUndo: Bool, hasMarkedText: Bool) {
            self.editable = editable; self.allowsUndo = allowsUndo
            self.canUndo = canUndo; self.hasMarkedText = hasMarkedText
        }
    }

    /// Whether focused text counts as being edited. Focus alone does not; an
    /// edit since focus does. A field that keeps no undo record can't say
    /// whether it was edited, so it counts.
    public static func isEditing(_ f: FocusedText) -> Bool {
        guard f.editable else { return false }
        if f.hasMarkedText { return true }
        return f.allowsUndo ? f.canUndo : true
    }

    public static func decide(_ s: Signals) -> Decision {
        // Never, however long the update has waited.
        if s.storeOpening { return .wait(.storeOpening) }
        if s.menuOpen { return .wait(.menuOpen) }
        // Unattended or not: what someone typed is theirs until they submit
        // it. The ceiling below does not reach past this.
        if s.editingText { return .wait(.editingText) }
        let away = s.userIdle >= userAwayAfter
        if s.sinceReady >= ceiling, away { return .install(.heldTooLong) }
        // Active is in use only while someone is there to use it: an active
        // Pacer nobody has touched for `userAwayAfter` falls through to the
        // same rules as an inactive one (an open dashboard installs as
        // `userAway`).
        if s.pacerActive, !away { return .wait(.inUse) }
        if s.otherWindowOpen { return .wait(.windowOpen) }
        // The overdue case too: someone who was using Pacer a minute ago may
        // still be reading it.
        if !(s.sinceUsed >= quietAfterUse) { return .wait(.recentlyUsed) }
        if !s.dashboardOpen { return .install(.noWindow) }
        if s.userIdle >= userAwayAfter { return .install(.userAway) }
        if s.sinceReady >= maxWait { return .install(.overdue) }
        return .wait(.dashboardOpen)
    }
}

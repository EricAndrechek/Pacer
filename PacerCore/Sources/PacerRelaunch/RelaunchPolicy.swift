/// When Pacer relaunches itself after exiting without quitting, and when it
/// stops (#412). Pure, so the crash-loop guard is tested without a crash.
///
/// Times are seconds since 1970: this module has no Foundation, so the
/// relauncher that links it stays a few hundred kilobytes.
public enum RelaunchPolicy {

    /// The wait before each relaunch in a row: 10 s, then 30 s, then 2 min.
    /// Its length is also the most relaunches allowed inside `window`; one
    /// more unexpected exit in that window and Pacer stays down.
    ///
    /// Not shorter than 10 s, for two things that finish after the process is
    /// gone: Launch Services forgetting the dead instance (until it does, the
    /// new one's single-instance gate would see it and exit), and Sparkle's
    /// installer. An update that is downloaded and waiting installs after any
    /// exit, a crash included, without relaunching; waiting lets that swap
    /// finish, so the relaunch starts the new version.
    public static let delays: [Int] = [10, 30, 120]

    /// How far back relaunches count towards the cap. A crash at launch hits
    /// the cap in under three minutes; a crash once an hour never does, and
    /// relaunches every time.
    public static let window: Double = 30 * 60

    public static var maxRelaunches: Int { delays.count }

    /// The relaunches in a row that led to this launch, this one included,
    /// to store for the next.
    ///
    /// Any launch that is not the relauncher's starts over: someone opened
    /// Pacer, the login item did, or Sparkle relaunched a new version. That
    /// is also how a Pacer that stopped relaunching comes back: opened by
    /// hand, it is protected again.
    public static func history(previous: [Double], relaunchedAfterCrash: Bool, now: Double) -> [Double] {
        guard relaunchedAfterCrash else { return [] }
        return recent(previous, now: now) + [now]
    }

    /// The entries inside the window. One in the future (the clock was set
    /// back) is dropped, so a changed clock can only ever allow a relaunch.
    public static func recent(_ history: [Double], now: Double) -> [Double] {
        history.filter { now - $0 >= 0 && now - $0 < window }
    }

    /// What the relauncher should do if this run exits without quitting.
    public static func instruction(history: [Double], now: Double) -> RelaunchInstruction {
        let count = recent(history, now: now).count
        guard count < delays.count else { return .stayDown(relaunches: count) }
        return .relaunch(afterSeconds: delays[count])
    }
}

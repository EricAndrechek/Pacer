/// What Pacer tells its relauncher, one line at a time, on the pipe that is
/// the relauncher's stdin. Pacer holds the only write end, so the kernel
/// closes it when Pacer's process ends, however it ends (SIGKILL included),
/// and the relauncher reads end-of-file. Whatever was said last decides what
/// happens then.
public enum RelaunchInstruction: Equatable, Sendable {
    /// An exit without quitting relaunches Pacer after this many seconds.
    case relaunch(afterSeconds: Int)
    /// An exit without quitting leaves Pacer closed: it already relaunched
    /// this many times inside the window (`RelaunchPolicy`).
    case stayDown(relaunches: Int)
    /// Pacer is quitting on purpose (Quit, ⌘Q, logout, an update): never
    /// relaunch. Final: nothing after it changes that.
    case quit

    public var line: String {
        switch self {
        case .relaunch(let seconds): "relaunch \(seconds)\n"
        case .stayDown(let relaunches): "stay-down \(relaunches)\n"
        case .quit: "quit\n"
        }
    }

    /// A line without its newline. Anything else is nil and ignored.
    public init?(line: some StringProtocol) {
        let words = line.split(separator: " ")
        guard let verb = words.first.map({ String($0) }) else { return nil }
        switch (verb, words.count) {
        case ("quit", 1):
            self = .quit
        case ("relaunch", 2):
            guard let seconds = Int(words[1]), (0...3600).contains(seconds) else { return nil }
            self = .relaunch(afterSeconds: seconds)
        case ("stay-down", 2):
            guard let relaunches = Int(words[1]), relaunches >= 0 else { return nil }
            self = .stayDown(relaunches: relaunches)
        default:
            return nil
        }
    }
}

/// The relauncher's reading of its input: bytes in, and at end-of-file, the
/// verdict. "Is this exit abnormal" is answered here: an exit is abnormal
/// exactly when Pacer's end closed without a `quit` before it.
public struct RelaunchWatch: Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Pacer said it was quitting, or never said anything: do nothing.
        case nothing
        case relaunch(afterSeconds: Int)
        case stayDown(relaunches: Int)
    }

    public private(set) var verdict: Verdict = .nothing
    public private(set) var quitting = false

    private var pending: [UInt8] = []
    private var overlong = false
    /// Every real line is under 20 bytes; anything longer is not ours.
    static let maxLine = 64

    public init() {}

    /// Lines can arrive split across reads. A partial last line is never
    /// acted on: Pacer's lines are single writes far below `PIPE_BUF`, which
    /// a pipe delivers whole, so a fragment is not something Pacer said.
    public mutating func receive(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                finishLine()
            } else if pending.count < Self.maxLine {
                pending.append(byte)
            } else {
                overlong = true
            }
        }
    }

    private mutating func finishLine() {
        defer {
            pending.removeAll(keepingCapacity: true)
            overlong = false
        }
        guard !overlong, !quitting,
              let instruction = RelaunchInstruction(line: String(decoding: pending, as: UTF8.self))
        else { return }
        switch instruction {
        case .quit:
            quitting = true
            verdict = .nothing
        case .relaunch(let seconds):
            verdict = .relaunch(afterSeconds: seconds)
        case .stayDown(let relaunches):
            verdict = .stayDown(relaunches: relaunches)
        }
    }
}

import Darwin

/// The relauncher's command line after its own path:
///
///     PacerRelauncher <pid> <process name> <command> [<argument>...]
///
/// The pid it watches, the name a running Pacer has (so it never starts a
/// second one), and the command that relaunches Pacer. Pacer builds the
/// command (`CrashRelaunch.relaunchCommand`), so the relauncher knows nothing
/// about how Pacer is launched, and a test can hand it a harmless one.
public struct RelauncherArguments: Equatable, Sendable {
    public var watchedPID: Int32
    public var processName: String
    public var command: [String]

    public init(watchedPID: Int32, processName: String, command: [String]) {
        self.watchedPID = watchedPID
        self.processName = processName
        self.command = command
    }

    public var arguments: [String] { [String(watchedPID), processName] + command }

    /// Nil unless the pid is a real one, the name is set, and the command is
    /// an absolute path.
    public init?(_ arguments: [String]) {
        guard arguments.count >= 3, let pid = Int32(arguments[0]), pid > 1,
              !arguments[1].isEmpty, arguments[2].hasPrefix("/")
        else { return nil }
        self.init(watchedPID: pid, processName: arguments[1], command: Array(arguments[2...]))
    }
}

/// The relauncher itself (`Relauncher/main.swift` is only its entry point).
///
/// It blocks reading its stdin until Pacer's end of the pipe closes, which
/// takes no CPU and no timer, then acts on the verdict once and exits. Every
/// side effect goes through `Effects`, so the whole run is tested with a real
/// pipe and nothing launched.
public enum Relauncher {

    public struct Effects {
        /// The process still exists (a zombie counts; launchd reaps fast).
        public var processAlive: (Int32) -> Bool
        /// A process with this name other than the given pid, if one runs.
        public var runningInstance: (_ name: String, _ excluding: Int32) -> Int32?
        public var sleep: (Double) -> Void
        /// Runs the command to completion; its exit status.
        public var run: ([String]) -> Int32
        public var log: (String) -> Void

        public init(processAlive: @escaping (Int32) -> Bool,
                    runningInstance: @escaping (String, Int32) -> Int32?,
                    sleep: @escaping (Double) -> Void,
                    run: @escaping ([String]) -> Int32,
                    log: @escaping (String) -> Void) {
            self.processAlive = processAlive
            self.runningInstance = runningInstance
            self.sleep = sleep
            self.run = run
            self.log = log
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Pacer quit on purpose, or said nothing.
        case quit
        case stayedDown(relaunches: Int)
        /// The input closed but the process did not go away.
        case stillRunning
        /// Someone brought Pacer back during the wait.
        case alreadyRunning(pid: Int32)
        case relaunched
        case launchFailed(status: Int32)
        /// Reading the input failed: there is no telling whether Pacer exited.
        case unwatchable
    }

    /// How long the watched process may take to disappear after its end
    /// closed. The kernel closes descriptors as the process exits, so this is
    /// normally instant.
    static let exitWait: Double = 10

    public static func run(_ arguments: RelauncherArguments, input: Int32, effects: Effects) -> Outcome {
        var watch = RelaunchWatch()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count > 0 {
                watch.receive(buffer[0..<count])
            } else if count == 0 {
                return act(on: watch.verdict, arguments, effects: effects)
            } else if errno != EINTR {
                effects.log("could not read from Pacer (errno \(errno)); not watching it")
                return .unwatchable
            }
        }
    }

    /// Pacer's end has closed: do what it said last.
    public static func act(on verdict: RelaunchWatch.Verdict, _ arguments: RelauncherArguments,
                           effects: Effects) -> Outcome {
        let pid = arguments.watchedPID
        switch verdict {
        case .nothing:
            return .quit
        case .stayDown(let relaunches):
            effects.log("Pacer (pid \(pid)) exited without quitting; not relaunching: "
                        + "\(relaunches) relaunches in the last \(Int(RelaunchPolicy.window / 60)) min. "
                        + "It starts again when opened.")
            return .stayedDown(relaunches: relaunches)
        case .relaunch(let seconds):
            effects.log("Pacer (pid \(pid)) exited without quitting; relaunching in \(seconds) s")
            var waited = 0.0
            while effects.processAlive(pid) {
                guard waited < exitWait else {
                    effects.log("Pacer (pid \(pid)) is still running; not relaunching")
                    return .stillRunning
                }
                effects.sleep(0.1)
                waited += 0.1
            }
            effects.sleep(Double(seconds))
            // Never a second instance: someone may have opened Pacer during
            // the wait. Starting another would only hit its single-instance
            // gate, at best.
            if let other = effects.runningInstance(arguments.processName, pid) {
                effects.log("Pacer is already running again (pid \(other)); not relaunching")
                return .alreadyRunning(pid: other)
            }
            let status = effects.run(arguments.command)
            guard status == 0 else {
                effects.log("relaunching Pacer failed: \(arguments.command[0]) exited with \(status)")
                return .launchFailed(status: status)
            }
            effects.log("relaunched Pacer")
            return .relaunched
        }
    }
}

extension Relauncher.Effects {
    /// The real ones.
    public static var live: Self {
        Self(processAlive: { pid in kill(pid, 0) == 0 || errno == EPERM },
             runningInstance: RelaunchProcess.running(named:excluding:),
             sleep: RelaunchProcess.sleep,
             run: RelaunchProcess.runToCompletion,
             log: { RelaunchLog.write($0) })
    }
}

/// Lines in Pacer's log format, `2026-05-07T01:42:13.482Z [Relauncher] …`,
/// written to stderr: Pacer points its stderr at its log file before it
/// starts the relauncher, which inherits it. Single `write`s far below
/// `PIPE_BUF`, appended to a file opened for append, so they never interleave
/// with Pacer's own lines.
public enum RelaunchLog {
    public static let tag = "Relauncher"

    public static func line(_ message: String, at time: timespec) -> String {
        var seconds = time_t(time.tv_sec)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let stamp = "\(pad(Int(parts.tm_year) + 1900, 4))-\(pad(Int(parts.tm_mon) + 1, 2))-\(pad(Int(parts.tm_mday), 2))"
            + "T\(pad(Int(parts.tm_hour), 2)):\(pad(Int(parts.tm_min), 2)):\(pad(Int(parts.tm_sec), 2))"
            + ".\(pad(Int(time.tv_nsec) / 1_000_000, 3))Z"
        return "\(stamp) [\(tag)] \(message)\n"
    }

    public static func write(_ message: String) {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let bytes = Array(line(message, at: now).utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}

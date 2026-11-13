import Darwin

/// The process plumbing on both sides: Pacer starting its relauncher and
/// talking to it, and the relauncher's view of the machine.
public enum RelaunchProcess {

    public struct Started: Equatable, Sendable {
        public let pid: Int32
        /// The pipe's write end. Only this process holds it.
        public let input: Int32
    }

    public enum Failure: Error, Equatable, Sendable {
        case pipe(errno: Int32)
        /// The pipe landed on stdin/stdout/stderr, which only happens if one
        /// of those was closed; not worth working around.
        case lowDescriptor
        case initialWrite(errno: Int32)
        case spawn(code: Int32)
    }

    /// Start `executable` with a pipe as its stdin, `initial` already in it,
    /// and return the write end.
    ///
    /// - `initial` is written before the child exists, so there is no moment
    ///   in which this process could die with nothing said.
    /// - Both pipe ends are close-on-exec, and the spawn closes every
    ///   descriptor it is not told to keep (`POSIX_SPAWN_CLOEXEC_DEFAULT`):
    ///   if anything else Pacer starts held the write end, end-of-file would
    ///   wait for that process too. The child keeps only the read end (as
    ///   stdin) and stderr (Pacer's log file); stdout is /dev/null.
    /// - The write end does not raise SIGPIPE (`F_SETNOSIGPIPE`): if the
    ///   relauncher is gone (killed by `bin/dev-quit-app.sh`, say), a later
    ///   write fails quietly instead of killing Pacer, and Sentry's crash
    ///   handler would otherwise report it as a crash.
    /// - `POSIX_SPAWN_SETSID` gives the child its own session and process
    ///   group. An app Launch Services starts is a launchd job, and when a
    ///   job exits launchd kills what is left in its process group
    ///   (launchd.plist, `AbandonProcessGroup`); the relauncher has to
    ///   outlive Pacer to do its one job. Its own session also keeps a
    ///   terminal's Ctrl-C or hangup away from it.
    public static func start(executable: String, arguments: [String],
                             initial: RelaunchInstruction) -> Result<Started, Failure> {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return .failure(.pipe(errno: errno)) }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        guard readEnd > STDERR_FILENO, writeEnd > STDERR_FILENO else {
            close(readEnd); close(writeEnd)
            return .failure(.lowDescriptor)
        }
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        guard send(initial, to: writeEnd) else {
            let code = errno
            close(readEnd); close(writeEnd)
            return .failure(.initialWrite(errno: code))
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let code = withCStrings([executable] + arguments) { argv in
            posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        close(readEnd)
        guard code == 0 else {
            close(writeEnd)
            return .failure(.spawn(code: code))
        }
        return .success(Started(pid: pid, input: writeEnd))
    }

    /// One whole line, in one write.
    @discardableResult
    public static func send(_ instruction: RelaunchInstruction, to input: Int32) -> Bool {
        let bytes = Array(instruction.line.utf8)
        while true {
            let written = bytes.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
            if written == bytes.count { return true }
            if written < 0, errno == EINTR { continue }
            return false
        }
    }

    /// Another process of this user with this name, from the kernel's process
    /// list rather than Launch Services, which may still list the instance
    /// that just died. This user's only: with fast user switching, another
    /// account's Pacer is not this one coming back.
    public static func running(named name: String, excluding: Int32) -> Int32? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        let me = getpid()
        let uid = getuid()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != excluding && pid != me {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_uid == uid,
                  proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            else { continue }
            if buffer.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == name { return pid }
        }
        return nil
    }

    public static func sleep(_ seconds: Double) {
        guard seconds > 0 else { return }
        var request = timespec(tv_sec: Int(seconds),
                               tv_nsec: Int((seconds - Double(Int(seconds))) * 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&request, &remaining) == -1, errno == EINTR { request = remaining }
    }

    /// Exit status, 128 + the signal if it was killed, or -1 if it could not
    /// be started.
    public static func runToCompletion(_ command: [String]) -> Int32 {
        guard let path = command.first else { return -1 }
        var pid: pid_t = 0
        let code = withCStrings(command) { argv in posix_spawn(&pid, path, nil, nil, argv, environ) }
        guard code == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

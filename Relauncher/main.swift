import Darwin
import PacerRelaunch

// PacerRelauncher, inside Pacer.app at Contents/Helpers (#412). Pacer starts
// one per run (`CrashRelauncher`), with a pipe as its stdin whose only write
// end Pacer holds. It blocks reading that pipe, which costs nothing, until
// the kernel closes Pacer's end as Pacer's process ends. If Pacer said `quit`
// first, it exits; otherwise Pacer crashed or was killed, and it relaunches
// Pacer after the delay Pacer gave it, or leaves it closed in a crash loop.
// Then it exits: the relaunched Pacer starts its own.
//
// The logic is `Relauncher.run` in PacerRelaunch, where `swift test` reaches it.

guard let arguments = RelauncherArguments(Array(CommandLine.arguments.dropFirst())) else {
    RelaunchLog.write("started with unusable arguments; not watching anything")
    exit(64)
}
_ = Relauncher.run(arguments, input: STDIN_FILENO, effects: .live)
exit(0)

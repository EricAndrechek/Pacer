import Foundation
import PacerPace

// `pacer`, the command line inside Pacer.app (#194). It lives at
// `Pacer.app/Contents/Helpers/PacerCLI.app/Contents/MacOS/pacer`, the executable
// of an app-like bundle signed into Pacer's App Group, so it can read the
// store when the local API is off. Every command is a library call: the logic
// is in `PacerPace`, where `swift test` reaches it.

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "-h", "--help", "help":
    FileHandle.standardOutput.write(Data(Pace.help.utf8))
    exit(0)
#if DEBUG
case "__crash-test":
    // Development builds only: crash on purpose so the end-to-end check can
    // watch macOS write the crash report and the app forward it to Sentry
    // (CrashReportForwardingService). Not in help, not in release builds.
    fatalError("Test crash from the pacer command line (development build)")
#endif
default:
    // No arguments is `report`, as it always was.
    let environment = ProcessInfo.processInfo.environment
    exit(Pace.runLogged(arguments, environment: environment,
                       io: .live(offline: .store, environment: environment)))
}

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
default:
    // No arguments is `report`, as it always was.
    exit(Pace.run(arguments, environment: ProcessInfo.processInfo.environment,
                  io: .live(offline: .store)))
}

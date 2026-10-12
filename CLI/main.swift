import Foundation
import PacerPace

// `pacer`, the command line inside Pacer.app (#194). It lives at
// `Pacer.app/Contents/Helpers/PacerCLI.app/Contents/MacOS/pacer`, the executable
// of an app-like bundle signed into Pacer's App Group, so it can read the
// store when the local API is off. Every command is a library call: the logic
// is in `PacerPace`, where `swift test` reaches it.

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: pacer pace <command> [options]

  pacer pace report      where every window stands, for this session's login
  pacer pace gate        exit 0 to go, 10 to pause
  pacer pace --help      every command and option

"""

switch arguments.first {
case "pace":
    exit(Pace.run(Array(arguments.dropFirst()), environment: ProcessInfo.processInfo.environment,
                  io: .live(offline: .store)))
case "-h", "--help", "help":
    FileHandle.standardOutput.write(Data(usage.utf8))
    exit(0)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

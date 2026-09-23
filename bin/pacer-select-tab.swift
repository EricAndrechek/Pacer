// Asks the running Pacer to show a sidebar tab — the app switches itself.
//
//   swiftc -O bin/pacer-select-tab.swift -o build/pacer-select-tab
//   build/pacer-select-tab history      # dashboard | history | projects | models | settings
//
// Posts `com.ericandrechek.pacer.selectDestination` (see ContentView). No input
// events and no activation: the window changes tab where it is, in the
// background, and focus stays wherever the owner left it.
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: pacer-select-tab <destination>\n".utf8))
    exit(64)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.ericandrechek.pacer.selectDestination"),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)

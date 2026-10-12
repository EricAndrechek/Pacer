import Foundation
import Testing

/// `Skills/pacer/pace.sh` is a shim now (#194): everything it does is find
/// `pacer` and hand it `pace` plus the arguments, or say it could not.
@Suite("pace.sh: the shim")
struct PaceShimTests {

    static var shimPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PacerPaceTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PacerCore
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Skills/pacer/pace.sh").path
    }

    /// A stand-in `pacer` that prints its arguments and exits 7.
    static func fakeCLI(at url: URL) throws {
        try "#!/bin/sh\necho \"args: $*\"\nexit 7\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func run(_ script: String, _ args: [String], env: [String: String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + args
        process.environment = ["PATH": "/usr/bin:/bin"].merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("hands `pace` and every argument to the command line, and its exit code back")
    func execs() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shim-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("fake-pacer")
        try Self.fakeCLI(at: cli)

        let (status, out) = Self.run(Self.shimPath, ["gate", "--cap", "85"], env: ["PACER_CLI": cli.path])
        #expect(status == 7)
        #expect(out == "args: pace gate --cap 85\n")
    }

    @Test("finds the `pacer` link Pacer puts beside the installed skill")
    func findsTheLinkBesideIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shim-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shim = dir.appendingPathComponent("pace.sh")
        try FileManager.default.copyItem(atPath: Self.shimPath, toPath: shim.path)
        try Self.fakeCLI(at: dir.appendingPathComponent("pacer"))

        let (status, out) = Self.run(shim.path, ["status"], env: [:])
        #expect(status == 7)
        #expect(out == "args: pace status\n")
    }

    @Test("without one: exit 2, which every caller reads as proceed ungated")
    func missing() {
        let (status, out) = Self.run(Self.shimPath, ["gate"], env: ["PACER_CLI": "/nonexistent/pacer"])
        #expect(status == 2)
        #expect(out.contains("command line was not found"))
        #expect(out.contains("Proceeding ungated"))
    }
}

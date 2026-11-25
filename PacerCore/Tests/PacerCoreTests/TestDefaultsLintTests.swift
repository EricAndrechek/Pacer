import Foundation
import Testing

/// A test that opens its own `UserDefaults(suiteName:)` leaves
/// `~/Library/Preferences/<suite>.plist` behind for good (#464). `TestDefaults`
/// is the only place allowed to, because it deletes the file.
@Suite struct TestDefaultsLintTests {
    @Test func noTestOpensItsOwnSuite() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let walker = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        let needle = "UserDefaults(" + "suiteName:"
        var offenders: [String] = []
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  !["TestDefaults.swift", "TestDefaultsLintTests.swift"].contains(url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(needle) { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "use TestDefaults / withTestDefaults, not a raw suite: \(offenders)")
    }
}

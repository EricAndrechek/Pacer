import Foundation
import Testing
@testable import PacerCore

@Suite struct SafeJSONTests {
    @Test func rejectsWhatWouldRaise() {
        #expect(SafeJSON.data(["x": Double.nan]) == nil)
        #expect(SafeJSON.data(["x": Double.infinity]) == nil)
        #expect(SafeJSON.data(["x": -Double.infinity]) == nil)
        #expect(SafeJSON.data(["x": Date()]) == nil)
        #expect(SafeJSON.data("a string") == nil)
        #expect(SafeJSON.data(["a": ["b": [1, Double.nan]]]) == nil)
    }

    @Test func serializesANormalPayload() throws {
        let data = try #require(SafeJSON.data(["a": 1, "b": ["c": "d"]], options: [.sortedKeys]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":{"c":"d"}}"#)
        #expect(SafeJSON.data([1, 2, 3]) != nil)
    }
}

/// A direct call to the raising API is a crash waiting for a NaN (#474).
@Suite struct SafeJSONLintTests {
    @Test func noDirectSerializationOutsideTheHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let needle = try NSRegularExpression(pattern: #"JSONSerialization\.data\(\s*withJSONObject"#)
        var offenders: [String] = []
        for sub in ["PacerCore/Sources", "App"] {
            let dir = root.appendingPathComponent(sub)
            let walker = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "swift", url.lastPathComponent != "SafeJSON.swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if needle.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "use SafeJSON.data: \(offenders)")
    }
}

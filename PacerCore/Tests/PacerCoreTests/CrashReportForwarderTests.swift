import Foundation
import Testing
@testable import PacerCore

// The fixture is the shape macOS 27 writes for a Swift `fatalError` in a
// command-line tool (verified against a real report on 2026-11-02), trimmed and
// with synthetic paths and ids.

@Suite("Crash report forwarder")
struct CrashReportForwarderTests {

    static let ips = """
    {"app_name":"pacer","timestamp":"2026-11-02 11:07:31.00 -0500","app_version":"0.8.0","slice_uuid":"33434d12-5757-3524-84da-a4caf748dab7","build_version":"1790000000","bug_type":"309","os_version":"macOS 27.0.1 (26A434)","incident_id":"9FFE509D-0766-40E1-BF08-BF53B3B7F00B"}
    {"procName":"pacer","procPath":"/Users/alice/Applications/Pacer.app/Contents/Helpers/PacerCLI.app/Contents/MacOS/pacer","captureTime":"2026-11-02 11:07:31.6421 -0500","osVersion":{"train":"macOS 27.0.1","build":"26A434"},"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"indicator":"Trace/BPT trap: 5"},"faultingThread":0,"threads":[{"frames":[{"imageOffset":1445196,"symbol":"_assertionFailure(_:_:file:line:flags:)","imageIndex":1},{"imageOffset":1992,"symbol":"level2(_:)","imageIndex":0},{"imageOffset":204416,"symbol":"start","imageIndex":2}]}],"usedImages":[{"name":"pacer","uuid":"33434d12-5757-3524-84da-a4caf748dab7","base":4362764288,"size":16384,"arch":"arm64"},{"name":"libswiftCore.dylib","uuid":"c9b36da7-bb34-35af-bc5d-91ecbcaa9ed0","base":7042973696,"size":5869104,"arch":"arm64e"},{"name":"dyld","uuid":"d341ddcb-7969-3a9c-8e03-0cf4751398a9","base":6696476672,"size":784100,"arch":"arm64e"},{"base":0,"size":0,"uuid":"00000000-0000-0000-0000-000000000000"}]}
    """

    private func event(_ text: String = ips) throws -> [String: Any] {
        let report = try #require(CrashReportForwarder.report(
            fromIPS: text, home: "/Users/alice",
            release: { v, b in "com.ericandrechek.pacer@\(v)+\(b)" }, environment: "production"))
        return try #require(try JSONSerialization.jsonObject(with: report.eventJSON) as? [String: Any])
    }

    @Test("frames are absolute addresses, oldest first, with macOS's symbol names")
    func frames() throws {
        let ev = try event()
        let values = try #require((ev["exception"] as? [String: Any])?["values"] as? [[String: Any]])
        let frames = try #require((values[0]["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        #expect(frames.count == 3)
        #expect(frames.first?["function"] as? String == "start")
        #expect(frames.last?["function"] as? String == "_assertionFailure(_:_:file:line:flags:)")
        // base 7042973696 + 1445196
        #expect(frames.last?["instruction_addr"] as? String == "0x1a3e14d4c")
        #expect(values[0]["type"] as? String == "EXC_BREAKPOINT")
    }

    @Test("debug images carry UUID and load address; the empty placeholder image is dropped")
    func images() throws {
        let ev = try event()
        let images = try #require((ev["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]])
        #expect(images.count == 3)
        #expect(images[0]["debug_id"] as? String == "33434d12-5757-3524-84da-a4caf748dab7")
        #expect(images[0]["image_addr"] as? String == "0x1040a8000")
    }

    @Test("release and process are set; the report's paths never appear")
    func releaseAndPrivacy() throws {
        let ev = try event()
        #expect(ev["release"] as? String == "com.ericandrechek.pacer@0.8.0+1790000000")
        #expect((ev["tags"] as? [String: Any])?["process"] as? String == "pacer")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ev), as: UTF8.self)
        #expect(!json.contains("alice"))
    }

    @Test("reports for other processes are ignored")
    func otherProcess() {
        let other = Self.ips.replacingOccurrences(of: "\"procName\":\"pacer\"", with: "\"procName\":\"Safari\"")
            .replacingOccurrences(of: "\"app_name\":\"pacer\"", with: "\"app_name\":\"Safari\"")
        #expect(CrashReportForwarder.report(fromIPS: other, release: { _, _ in nil }, environment: "x") == nil)
    }

    @Test("a truncated report is skipped, not crashed on")
    func truncated() {
        #expect(CrashReportForwarder.report(fromIPS: String(Self.ips.prefix(400)),
                                            release: { _, _ in nil }, environment: "x") == nil)
    }

    @Test("only Pacer's report files are candidates")
    func candidates() {
        #expect(CrashReportForwarder.isCandidate(fileName: "pacer-2026-11-02-110731.ips"))
        #expect(CrashReportForwarder.isCandidate(fileName: "PacerWidgets-2026-11-02-110731.ips"))
        #expect(CrashReportForwarder.isCandidate(fileName: "Pacer-2026-11-02-110731.ips"))
        #expect(!CrashReportForwarder.isCandidate(fileName: "pacertest-crashy-2026-11-02-110731.ips"))
        #expect(!CrashReportForwarder.isCandidate(fileName: "SFA-ckks.json_2026-11-02.diag"))
    }
}

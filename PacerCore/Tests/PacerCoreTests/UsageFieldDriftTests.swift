import Foundation
import Testing
@testable import PacerCore

@Suite("Unknown transcript usage fields")
struct UsageFieldDriftTests {

    private func line(usage: String) -> Data {
        Data(#"{"type":"assistant","message":{"model":"m","usage":\#(usage)}}"#.utf8)
    }

    @Test("known keys, including the ignored ones, report nothing")
    func known() {
        let usage = #"{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4,"cache_creation":{},"speed":"standard","inference_geo":"x","iterations":[],"output_tokens_details":{"thinking_tokens":5},"service_tier":"standard","server_tool_use":{}}"#
        #expect(FormatDrift.unknownUsageKeys(inLine: line(usage: usage)).isEmpty)
    }

    @Test("a new key is reported, sorted and made identifier-safe")
    func unknown() {
        let keys = FormatDrift.unknownUsageKeys(inLine: line(usage: #"{"input_tokens":1,"Thinking-Tokens":5,"a b/c":1}"#))
        #expect(keys == ["a_b_c", "thinking_tokens"])
    }

    @Test("fallback_credit stays on the watch while it is null")
    func fallbackCredit() {
        let keys = FormatDrift.unknownUsageKeys(inLine: line(usage: #"{"input_tokens":1,"fallback_credit":null}"#))
        #expect(keys == ["fallback_credit"])
    }

    @Test("the key is cut to 40 characters")
    func cap() {
        let long = String(repeating: "k", count: 90)
        let keys = FormatDrift.unknownUsageKeys(inLine: line(usage: "{\"\(long)\":1}"))
        #expect(keys.first?.count == 40)
    }

    @Test("lines without a usage object, or not JSON, report nothing")
    func noUsage() {
        #expect(FormatDrift.unknownUsageKeys(inLine: Data(#"{"type":"user","message":{"content":"x"}}"#.utf8)).isEmpty)
        #expect(FormatDrift.unknownUsageKeys(inLine: Data("{truncated".utf8)).isEmpty)
    }
}

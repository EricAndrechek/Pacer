import Foundation
import Testing
@testable import PacerCore

@Suite("Decoding a price catalog")
struct PricingTableDecodeTests {
    /// A top-level value that isn't an object used to reach
    /// `JSONSerialization.data(withJSONObject:)`, which raises an Objective-C
    /// exception for it: a crash, not a skipped entry.
    @Test func valuesThatAreNotObjectsAreSkipped() throws {
        let json: [String: Any] = [
            "claude-sonnet-4-5": [
                "input_cost_per_token": 0.000003,
                "output_cost_per_token": 0.000015,
                "litellm_provider": "anthropic",
            ],
            "a-string": "not a model",
            "a-number": 42,
            "a-null": NSNull(),
            "an-array": [1, 2, 3],
        ]
        let table = PricingTable.decode(json: json)
        #expect(table.keys.sorted() == ["claude-sonnet-4-5"])
    }
}

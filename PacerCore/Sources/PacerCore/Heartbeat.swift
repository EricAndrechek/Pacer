import Foundation
import SwiftData

@Model
public final class Heartbeat {
    public var timestamp: Date
    public var source: String

    public init(source: String, timestamp: Date = Date()) {
        self.source = source
        self.timestamp = timestamp
    }
}

import Foundation

/// A serial queue for calls that wait on a daemon over XPC.
///
/// `UNUserNotificationCenter.removePendingNotificationRequests` and its
/// siblings block on a synchronous reply from the notification daemon; on a
/// starved Mac that was 2 s or more on the main thread at launch (PACER-1G).
/// The center is documented thread-safe, so those calls go here instead. One
/// serial queue, not a concurrent one, so a remove issued after another still
/// lands after it.
public final class OffMainQueue: Sendable {
    public static let notifications = OffMainQueue(label: "com.ericandrechek.pacer.notification-center")

    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    public func run(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

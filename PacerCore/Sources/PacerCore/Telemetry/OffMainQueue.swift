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

    /// Run `work` on the queue and wait for it to finish, without blocking
    /// the caller's thread. Use it when what comes next has to land after the
    /// work. A window's reset removes its delivered alert, then posts the
    /// reset notice under the same identifier: with a fire-and-forget remove,
    /// the post could reach the notification daemon first, and the remove
    /// would then delete the notice just delivered.
    public func perform(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                done.resume()
            }
        }
    }
}

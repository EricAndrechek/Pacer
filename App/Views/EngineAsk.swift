import Foundation
import PacerCore

/// Ask the engine from a view without doing its work on the main thread.
///
/// `await engine.something()` inside a `@MainActor` view reads as "hop to the
/// engine's actor" and usually isn't. Under Swift's uncontended-actor
/// optimisation the callee runs **inline on the calling thread** when the
/// target actor is free — which, for a background actor that is idle between
/// five-minute refits, is almost always. So a `.task { await engine.ask(...) }`
/// in a view body executes the forecast fit on the main thread.
///
/// This is not theoretical. `PaceChartCard` already carried a comment about it,
/// confirmed with `sample(1)` during a scroll. Every *other* engine caller was
/// written without it, and a launch-time profile put
/// `MenuStatusContent.body → refreshEngine → burnOutlook → DiurnalBurnModel.fit`
/// at the top of main-thread time — 590 of the samples in a ten-second window,
/// inside a **7.9 second** stall.
///
/// A detached task has no isolation to inherit, so the work goes to the
/// cooperative pool where it belongs. Every engine ask from a view goes through
/// here.
@discardableResult
func askEngine<T: Sendable>(
    _ body: @escaping @Sendable () async -> T
) async -> T {
    await Task.detached(priority: .userInitiated, operation: body).value
}

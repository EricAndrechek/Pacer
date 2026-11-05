import Observation
import SwiftData
import PacerCore

/// Whether the app's store is open yet, for everything that needs it.
///
/// On an ordinary launch the store opens synchronously in
/// `PacerAppDelegate.init`, exactly as it always did, and the loader starts out
/// `.ready`. Only the first launch after an update that changed the schema
/// starts `.opening`: SwiftData migrates the store in place while it opens it,
/// for as long as the store is big, and that now happens off the main thread
/// (`PacerStore.prepareStore`, #376). Until it is done the dashboard shows
/// `StoreOpeningView`, and the scan, the poller, the menu bar item and the
/// check-in wait for `PacerAppDelegate.storeDidOpen`.
///
/// `@Observable` so `DashboardRoot` redraws when it changes; mutated only on
/// the main actor, by the delegate.
@MainActor @Observable
final class StoreLoader {
    /// What a view tree needs once the store is open: the container, and the
    /// engines built on it (they are created with the background service, in
    /// the same main-actor turn the state turns `.ready`).
    struct Ready {
        let container: ModelContainer
        let engine: UsageIntelligenceEngine
        let engines: EngineHost

        init(container: ModelContainer, service: AppBackgroundService) {
            self.container = container
            self.engine = service.engine
            self.engines = service.engines
        }
    }

    enum State {
        case opening
        case ready(Ready)
        /// The alert (`showFatalContainerError`) is already up over this.
        case failed(any Error)
    }

    private(set) var state: State

    /// An ordinary launch: the store opened before anything could ask.
    init(ready: Ready) { state = .ready(ready) }

    /// A launch that migrates the store first.
    init() { state = .opening }

    var ready: Ready? {
        if case .ready(let ready) = state { return ready }
        return nil
    }

    var container: ModelContainer? { ready?.container }

    func markReady(_ ready: Ready) { state = .ready(ready) }

    func markFailed(_ error: any Error) { state = .failed(error) }
}

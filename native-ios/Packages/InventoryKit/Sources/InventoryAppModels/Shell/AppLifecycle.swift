import Observation

/// Routes the app coming to the front and going away to the models that care, in RN's order
/// (09 §6).
///
/// The app target reports SwiftUI's scene phase at the `App` level as an ``AppActivity``
/// (``activityChanged(_:)``); nothing else in the app listens to it. RN had two listeners:
/// - `SyncProvider`: every transition to `active`, including `inactive → active` (Control
///   Center, the app switcher, a system alert closing), runs a sync pass (photos, then a backup
///   if 15 minutes have passed);
/// - `ConnectionProvider`: every change updates its app state, which drives the paired resume
///   refresh (on `active`) and the offline health ping (only while `active`).
///
/// Handlers run in ``Stage`` order: sync first, then the connection, as RN's effects
/// registered their listeners (child effects first: `SyncProvider` sits inside
/// `ConnectionProvider`). Nothing happens on background beyond telling the connection to stop
/// pinging; there are no flushes and no background tasks.
///
/// Only changes are routed: reporting the activity the app is already in does nothing, as RN's
/// `AppState` fired only on change.
@MainActor
@Observable
public final class AppLifecycle {
    /// Where a handler runs relative to the others.
    public enum Stage: Int, Comparable, Sendable, CaseIterable {
        /// The sync pass on `.active` (`SyncModel.onActive()`).
        case sync
        /// The connection's resume refresh and ping gating (`ConnectionModel`).
        case connection
        /// Anything added later.
        case other

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A registered handler; pass it back to ``unregister(_:)``.
    public struct Registration: Hashable, Sendable {
        let id: Int
    }

    private struct Handler {
        let id: Int
        let stage: Stage
        let handle: @MainActor (AppActivity) -> Void
    }

    /// The activity last reported.
    public private(set) var activity: AppActivity

    @ObservationIgnored private var handlers: [Handler] = []
    @ObservationIgnored private var nextID = 0

    /// - Parameter initial: the activity before the first report; the app reports the real one
    ///   as soon as its scene has a phase.
    public init(initial: AppActivity = .inactive) {
        activity = initial
    }

    /// Calls `handler` with every change of activity, after the handlers of earlier stages and
    /// after those already registered for the same stage.
    @discardableResult
    public func register(_ stage: Stage, _ handler: @escaping @MainActor (AppActivity) -> Void) -> Registration {
        nextID += 1
        handlers.append(Handler(id: nextID, stage: stage, handle: handler))
        return Registration(id: nextID)
    }

    /// Calls `action` on every transition to `.active` (the sync pass).
    @discardableResult
    public func whenActive(_ stage: Stage, perform action: @escaping @MainActor () -> Void) -> Registration {
        register(stage) { activity in
            if activity.isActive { action() }
        }
    }

    /// Stops calling a handler.
    public func unregister(_ registration: Registration) {
        handlers.removeAll { $0.id == registration.id }
    }

    /// The app's scene phase changed. Runs every handler, in stage order, when it really changed.
    public func activityChanged(_ next: AppActivity) {
        guard next != activity else { return }
        activity = next
        let ordered = handlers.enumerated().sorted { lhs, rhs in
            (lhs.element.stage, lhs.offset) < (rhs.element.stage, rhs.offset)
        }
        for (_, handler) in ordered {
            handler.handle(next)
        }
    }
}

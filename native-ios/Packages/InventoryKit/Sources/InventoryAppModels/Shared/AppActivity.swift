/// Whether the app is in front, as models see it: SwiftUI's `ScenePhase` without SwiftUI.
///
/// RN: `AppState` (`'active' | 'inactive' | 'background'`), read by `SyncProvider`
/// (src/providers/SyncProvider.tsx:118-120: every transition to `active`, including
/// `inactive → active`, runs a sync pass) and `ConnectionProvider` (:144-158: resume refresh
/// and the ping loop, which runs only while active). The app target maps `scenePhase` to this
/// at the `App` level (09 §6); nothing happens on background.
public enum AppActivity: Sendable, Hashable {
    /// In front and receiving events.
    case active
    /// In front but not receiving events: Control Center, the app switcher, a system alert.
    case inactive
    /// Not visible.
    case background

    /// RN `appState === 'active'`: the only state in which pings run and passes start.
    public var isActive: Bool { self == .active }
}

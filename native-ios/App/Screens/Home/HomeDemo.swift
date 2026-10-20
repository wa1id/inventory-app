#if DEBUG
import InventoryAppModels

/// DEBUG demo hooks for the home area: Home, Spaces and the Drop zone tab.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea home -demoState <state> [-demoRoute <spec>]`.
///
/// The home area fills these in (they start empty) and never edits `ShellDemo.swift`. Ideas:
///   - a paired household answering Home's reads from a fake transport;
///   - a long drop-zone backlog;
///   - a search already typed.
enum HomeDemo {
    /// The container to run on for `state`, or nil for the default demo container (the seeded
    /// inventory in memory, or an empty one with `-demoSeed empty`). Called before anything
    /// shows; build it with `AppContainer.preview(platform: platform, …)` so nothing on the
    /// device is touched.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        nil
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`: put `app` in
    /// `state` (write records through `app.repositories`, start a model, show a notice).
    @MainActor
    static func run(state: String, app: AppContainer) async {}
}
#endif

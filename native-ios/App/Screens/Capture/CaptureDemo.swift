#if DEBUG
import InventoryAppModels

/// DEBUG demo hooks for the capture area: the camera, Quick Snap and its review.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea capture -demoState <state> [-demoRoute <spec>]`.
///
/// The capture area fills these in (they start empty) and never edits `ShellDemo.swift`. Ideas:
///   - a seeded Quick Snap review with shots still processing;
///   - a camera permission that was denied;
///   - a Keep shooting session.
enum CaptureDemo {
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

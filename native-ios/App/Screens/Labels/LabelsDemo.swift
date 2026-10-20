#if DEBUG
import InventoryAppModels

/// DEBUG demo hooks for the labels area: the Scan tab, the label link, the QR label and linking a sticker.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea labels -demoState <state> [-demoRoute <spec>]`.
///
/// The labels area fills these in (they start empty) and never edits `ShellDemo.swift`. Ideas:
///   - a label bound to a container that was since deleted;
///   - the Scan tab's typed-code phase;
///   - a household whose QR reads answer from a fake transport.
enum LabelsDemo {
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

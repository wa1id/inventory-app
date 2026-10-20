import SwiftUI
import InventoryAppModels

// The shell's own environment entries (App/Shared/AppEnvironment.swift is shared and frozen).
extension EnvironmentValues {
    /// Where this screen is shown: a tab root, a pushed screen or a modal's root. Screens pass it
    /// back to the router to replace or close themselves, register removal hooks
    /// (`router.onRemoval(of:)`) and close guards (`.sheetCloseGuard`). Nil outside the shell.
    @Entry var screenAddress: ScreenAddress?

    /// The window's size, set at the root, for layouts that follow the window rather than their
    /// container (the bottom bar stacks below 360 pt, 08 §9.2 (14)) and for measuring bottom
    /// chrome from the window's bottom edge.
    @Entry var shellWindowSize: CGSize = .zero

    /// Posts a VoiceOver announcement that interrupts (error states, the removed-phone layer).
    /// The shell sets it from the platform; previews stay silent.
    @Entry var shellAnnounce: @MainActor @Sendable (String) -> Void = { _ in }

    /// The tab bar's toast chrome, shared by the main shell's tab bar and the overlay's toast.
    /// The root view sets it; nil elsewhere (previews put the toast above the safe area).
    @Entry var shellTabBarChrome: ShellTabBarChrome?
}

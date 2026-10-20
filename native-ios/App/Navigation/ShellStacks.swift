import SwiftUI
import InventoryAppModels
import InventoryStrings

/// A tab's navigation stack, bound to the router's path for that tab (06 §1, U5 per-tab stacks).
/// The root and every pushed screen get their address and focus in the environment.
struct ShellTabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder let root: () -> Root
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack(path: Binding(get: { router.path(tab) }, set: { router.setPath($0, for: tab) })) {
            root()
                .environment(\.screenAddress, .tabRoot(tab))
                .environment(\.isScreenFocused, router.isFocused(.tabRoot(tab)))
                .navigationDestination(for: PushEntry.self) { entry in
                    PushRouteDestination(entry: entry)
                }
        }
    }
}

/// A pushed screen with its address and focus.
struct PushRouteDestination: View {
    let entry: PushEntry
    @Environment(Router.self) private var router

    var body: some View {
        PushRouteScreen(route: entry.route)
            .environment(\.screenAddress, entry.address)
            .environment(\.isScreenFocused, router.isFocused(entry.address))
    }
}

/// Presents the modal stack's sheet or cover at `level` over the view, recursively: each modal
/// presents the next level from its own content, so a sheet can sit over a sheet and a cover over
/// a sheet (06 §3.1, D-8 keeps toasts above them all in the overlay window).
///
/// A swipe-down (or `dismiss()` from inside) tells the router, which removes that modal and
/// everything over it, abandoning its pending result; when the dismissal animation ends, a
/// search-focus request waiting for the transition may focus Home.
struct ShellModalPresentation: ViewModifier {
    let level: Int
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        let sheetID = router.sheet(atLevel: level)?.id
        let coverID = router.cover(atLevel: level)?.id
        content
            .sheet(
                item: Binding(
                    get: { router.sheet(atLevel: level) },
                    set: { if $0 == nil, let sheetID { router.modalDismissedBySystem(sheetID) } }
                ),
                onDismiss: { router.modalDismissalFinished() }
            ) { modal in
                ShellModalScreen(modal: modal, level: level)
            }
            .fullScreenCover(
                item: Binding(
                    get: { router.cover(atLevel: level) },
                    set: { if $0 == nil, let coverID { router.modalDismissedBySystem(coverID) } }
                ),
                onDismiss: { router.modalDismissalFinished() }
            ) { modal in
                ShellModalScreen(modal: modal, level: level)
            }
    }
}

/// A presented sheet or cover: its own navigation stack, the shell's Cancel on sheets (except the
/// Add sheet, which draws its own), and the next modal level.
struct ShellModalScreen: View {
    let level: Int
    @State private var shown: ModalEntry
    @Environment(Router.self) private var router

    init(modal: ModalEntry, level: Int) {
        self.level = level
        _shown = State(initialValue: modal)
    }

    var body: some View {
        // While it animates away the router no longer has it: keep drawing what was shown.
        let modal = router.modal(shown.id) ?? shown
        NavigationStack(path: Binding(get: { router.modal(modal.id)?.path ?? [] }, set: { router.setModalPath($0, modal: modal.id) })) {
            ModalRouteScreen(route: modal.route)
                .id(modal.screenID)
                .environment(\.screenAddress, modal.address)
                .environment(\.isScreenFocused, router.isFocused(modal.address))
                .toolbar {
                    if modal.route.usesShellCancel {
                        ToolbarItem(placement: .cancellationAction) {
                            ShellSheetCancel(address: modal.address)
                        }
                    }
                }
                .navigationDestination(for: PushEntry.self) { entry in
                    PushRouteDestination(entry: entry)
                }
        }
        .modifier(ShellModalPresentation(level: level + 1))
        .onChange(of: router.modal(shown.id)) { _, current in
            if let current { shown = current }
        }
    }
}

/// The top left of every sheet: "Cancel", which closes the sheet the way a swipe-down would, so
/// a dirty form's guard asks first (RN `SheetClose`, app/_layout.tsx:57-90; 06 §2.1).
struct ShellSheetCancel: View {
    let address: ScreenAddress
    @Environment(Router.self) private var router

    var body: some View {
        Button(L10n.Common.cancel) {
            Task { await router.requestClose(address) }
        }
        .accessibilityIdentifier("sheet-close")
    }
}

extension View {
    /// What the sheet's Cancel asks before it closes this screen (a dirty form's "Discard your
    /// changes?"): return true to close. Pair it with `.interactiveDismissDisabled(…)`, which
    /// stops the swipe-down while the guard would ask.
    func sheetCloseGuard(_ guardClose: @escaping @MainActor () async -> Bool) -> some View {
        modifier(ShellSheetCloseGuard(guardClose: guardClose))
    }
}

private struct ShellSheetCloseGuard: ViewModifier {
    let guardClose: @MainActor () async -> Bool
    @Environment(Router.self) private var router
    @Environment(\.screenAddress) private var address

    func body(content: Content) -> some View {
        content.onAppear {
            if let address { router.setCloseGuard(for: address, guardClose) }
        }
    }
}

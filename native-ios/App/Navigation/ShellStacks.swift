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
///
/// When the router swaps the modal at this level for another one (the camera replaced by the Add
/// sheet, the Add sheet by the camera, or a sheet closed and a new sheet opened at once, as the
/// place picker does when New space hands over to New container), the new one is presented only
/// once the old one has finished going away. UIKit refuses a presentation while the same
/// presenter is still dismissing, which left the router showing a sheet nobody could see; and a
/// sheet whose item changed while it was going away came back with the old screen in it.
/// Replacing a modal's root with one of the same kind keeps its id, so that swap stays in place.
struct ShellModalPresentation: ViewModifier {
    let level: Int
    @Environment(Router.self) private var router
    /// The modal handed to SwiftUI at this level, kept until its dismissal has finished.
    @State private var presented: ShellModalSlot?

    func body(content: Content) -> some View {
        let wanted = currentSlot
        content
            .sheet(
                item: Binding(
                    get: { presented != nil && presented == currentSlot && presented?.kind == .sheet ? router.sheet(atLevel: level) : nil },
                    set: { if $0 == nil, let presented, presented.kind == .sheet { router.modalDismissedBySystem(presented.id) } }
                ),
                onDismiss: { dismissalFinished() }
            ) { modal in
                ShellModalScreen(modal: modal, level: level)
            }
            .fullScreenCover(
                item: Binding(
                    get: { presented != nil && presented == currentSlot && presented?.kind == .cover ? router.cover(atLevel: level) : nil },
                    set: { if $0 == nil, let presented, presented.kind == .cover { router.modalDismissedBySystem(presented.id) } }
                ),
                onDismiss: { dismissalFinished() }
            ) { modal in
                ShellModalScreen(modal: modal, level: level)
            }
            .onChange(of: wanted, initial: true) { _, wanted in
                // Nothing on screen (or the same modal again): present at once. Otherwise the
                // old modal's onDismiss hands over.
                if presented == nil || presented == wanted, let wanted { presented = wanted }
            }
            .task(id: wanted) {
                // Never stuck waiting for a dismissal SwiftUI did not report (a modal replaced
                // before it was ever presented): after a second, show what the router has.
                guard let wanted, presented != wanted else { return }
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled, let current = currentSlot, presented != current { presented = current }
            }
    }

    /// The modal the router has at this level now.
    private var currentSlot: ShellModalSlot? {
        if let sheet = router.sheet(atLevel: level) { return ShellModalSlot(kind: .sheet, id: sheet.id) }
        if let cover = router.cover(atLevel: level) { return ShellModalSlot(kind: .cover, id: cover.id) }
        return nil
    }

    private func dismissalFinished() {
        presented = currentSlot
        router.modalDismissalFinished()
    }
}

/// Which modifier presents the modal at a level.
enum ShellModalKind: Hashable {
    case sheet
    case cover
}

/// The modal at a level: its kind and its id. A new id is a new presentation.
struct ShellModalSlot: Hashable {
    let kind: ShellModalKind
    let id: Int
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

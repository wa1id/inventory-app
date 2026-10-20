import SwiftUI
import InventoryAppModels

/// A model that re-reads with screen focus and the global revision (09 §5): every
/// `InventoryQuery`, and the models built on the same rule.
@MainActor
protocol ShellFocusDriven: AnyObject {
    func focusChanged(_ focused: Bool, revision: Int?)
    func revisionChanged(_ revision: Int)
}

extension InventoryQuery: ShellFocusDriven {}
extension DropZoneModel: ShellFocusDriven {}
extension SearchModel: ShellFocusDriven {}
extension HomeModel: ShellFocusDriven {}

extension View {
    /// Drives `query` (or any focus-driven model) from this screen: its focus (the
    /// `isScreenFocused` environment the shell sets from the router) and `DatabaseModel.revision`,
    /// each reported once per change, the focus first with the revision it caught up to.
    func inventoryQuery(_ query: some ShellFocusDriven) -> some View {
        modifier(ShellFocusDriving(model: query))
    }

    /// Ticks `ticker` only while this screen is focused, catching up when it is focused again
    /// (RN `useNow`).
    func nowTicker(_ ticker: NowTicker) -> some View {
        modifier(ShellNowTicking(ticker: ticker))
    }
}

private struct ShellFocusDriving<Model: ShellFocusDriven>: ViewModifier {
    let model: Model
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(AppContainer.self) private var app

    func body(content: Content) -> some View {
        content
            .onChange(of: isScreenFocused, initial: true) { _, focused in
                model.focusChanged(focused, revision: app.database.revision)
            }
            .onChange(of: app.database.revision) { _, revision in
                model.revisionChanged(revision)
            }
            // A screen taken away while in front (a reset) must not keep reading in the background.
            .onDisappear { model.focusChanged(false, revision: nil) }
    }
}

private struct ShellNowTicking: ViewModifier {
    let ticker: NowTicker
    @Environment(\.isScreenFocused) private var isScreenFocused

    func body(content: Content) -> some View {
        content
            .onChange(of: isScreenFocused, initial: true) { _, focused in
                ticker.focusChanged(focused)
            }
            .onDisappear { ticker.focusChanged(false) }
    }
}

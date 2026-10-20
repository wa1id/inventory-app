import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Move or File one item (RN app/item/[id]/move.tsx, 07 §3.5): the one place picker, grouped by
/// space and filterable, with the item's own container shown as "Here now" and unavailable.
///
/// Opened from the item screen (Move…, File it…) and from the Drop zone's File…, usually with a
/// `request` the opener awaits. A pick writes with the item's lock; on success the sheet closes
/// and a toast says where the item went, with Undo, whoever opened it. A pick that did not move
/// anything keeps the sheet open with a warning banner above the picker, announced at once
/// (with Close when the item is gone). While a pick writes the sheet resists a swipe-down; the
/// shell's Cancel still closes it, and the move then finishes with its toast.
///
/// The logic is ``MoveModel`` (package); the picker is the foundation's `PlacePickerHost`.
struct MoveSheet: View {
    let itemId: String
    let filing: Bool
    let request: RouteRequest<MoveResult>?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var query: InventoryQuery<ItemWithContext?>?
    @State private var move: MoveModel?

    init(itemId: String, filing: Bool, request: RouteRequest<MoveResult>?) {
        self.itemId = itemId
        self.filing = filing
        self.request = request
    }

    var body: some View {
        ScreenFrame(.modal) {
            if let query, let move {
                content(query, move)
                    .inventoryQuery(query)
            } else {
                // Something to appear, so `onAppear` makes the model (an empty view would not).
                Color.clear
            }
        }
        .navigationTitle(move?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(move?.interactiveDismissDisabled ?? false)
        // A container, so the screen's identifier does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-move")
        .onAppear {
            guard move == nil else { return }
            let repositories = app.repositories
            let itemId = itemId
            let read = InventoryQuery<ItemWithContext?>(key: "item:\(itemId)", revision: app.database.revision) {
                try await repositories.items.getById(itemId)
            }
            let made = Self.makeModel(app: app, filing: filing, request: request, address: address)
            made.follow(read)
            query = read
            move = made
            // Closing without a pick answers the opener with nothing (the router abandons it too).
            if let address { app.router.onRemoval(of: address) { made.sheetClosed() } }
        }
        #if DEBUG
        .task(id: move?.item?.id) {
            if let move, move.item != nil { await ItemDemo.moveLoaded(move, app: app) }
        }
        #endif
    }

    @ViewBuilder
    private func content(_ query: InventoryQuery<ItemWithContext?>, _ move: MoveModel) -> some View {
        if let item = move.item {
            PlacePickerHost(mode: move.pickerMode, currentContainerId: item.containerId, busyId: move.busyId) { place in
                Task { await move.pick(place) }
            }
            // Above the picker rather than in its list (RN move.tsx:80-94), so it is seen and
            // announced however far the list was scrolled: a list row off screen is neither.
            .pinnedNotice {
                if let notice = move.notice {
                    BannerView(
                        tone: .warning,
                        message: notice.message,
                        primary: notice.kind == .gone ? BannerAction(label: L10n.Common.close, identifier: "move-notice-close") { close() } : nil,
                        live: .assertive,
                        identifier: "move-notice"
                    )
                }
            }
        } else if let cause = query.cause {
            ItemStateScroll {
                ErrorStateView(cause: .failed(cause), subject: .item, onRetry: { query.reload() })
            }
        } else if query.isLoading {
            ScrollView {
                SkeletonView(variant: .options)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
        } else {
            // Deleted on another phone before the sheet opened: say so, write nothing.
            ItemStateScroll {
                ErrorStateView(
                    cause: .gone,
                    subject: .item,
                    secondary: StateAction(label: L10n.Common.close) { close() }
                )
            }
        }
    }

    private func close() {
        if let address { app.router.close(address) }
    }

    /// The model with the app's wiring: the current repositories, the route results, recent
    /// places, the database, toasts, haptics and the router.
    static func makeModel(app: AppContainer, filing: Bool, request: RouteRequest<MoveResult>?, address: ScreenAddress?) -> MoveModel {
        let router = app.router
        return MoveModel(
            items: app.repositories.items,
            filing: filing,
            request: request,
            routeResults: router.results,
            recentPlaces: app.recentPlaces,
            invalidator: app.database,
            toasts: app.toasts,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            isFocused: { address.map { router.isFocused($0) } ?? false },
            close: {
                if let address { router.close(address) }
            }
        )
    }
}

#if DEBUG
#Preview("Move") {
    ShellPreviewHost {
        NavigationStack { MovePreviewRoute(name: "Cordless drill") }
    }
}

#Preview("File") {
    ShellPreviewHost {
        NavigationStack { MovePreviewRoute(name: "HDMI cable") }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { MoveSheet(itemId: "missing", filing: false, request: nil) }
    }
}

/// Finds a seeded item by name and moves it.
private struct MovePreviewRoute: View {
    let name: String
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        Group {
            if let id { MoveSheet(itemId: id, filing: false, request: nil) }
        }
        .task {
            let items = (try? await app.repositories.items.listRecent(limit: 100)) ?? []
            id = items.first { $0.name == name }?.id
        }
    }
}
#endif

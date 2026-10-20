import SwiftUI
import InventoryAppModels

/// The screen for each pushed route (06 §3.1). Payloads carry only what the route needs; screens
/// reach everything else through `@Environment(AppContainer.self)` and the router.
struct PushRouteScreen: View {
    let route: PushRoute

    var body: some View {
        switch route {
        case .settings: SettingsScreen()
        case .privacy: PrivacyScreen()
        case .household: HouseholdScreen()
        case .backup: BackupScreen()
        case .label(let token): LabelLinkScreen(token: token)
        case .space(let id): SpaceDetailScreen(id: id)
        case .container(let id): ContainerDetailScreen(id: id)
        case .qrLabel(let containerId): QrLabelScreen(containerId: containerId)
        case .item(let id, let filing): ItemDetailScreen(id: id, filing: filing)
        case .quickSnapReview(let route): QuickSnapReviewScreen(route: route)
        }
    }
}

/// The screen for each sheet and cover (06 §3.1).
struct ModalRouteScreen: View {
    let route: ModalRoute

    var body: some View {
        switch route {
        case .sheet(let sheet): SheetRouteScreen(route: sheet)
        case .cover(let cover): CoverRouteScreen(route: cover)
        }
    }
}

private struct SheetRouteScreen: View {
    let route: SheetRoute

    var body: some View {
        switch route {
        case .addItem(let params): AddSheet(params: params)
        case .spaceNew(let request): SpaceNewSheet(request: request)
        case .spaceEdit(let id): SpaceEditSheet(id: id)
        case .containerNew(let spaceId, let request): ContainerNewSheet(spaceId: spaceId, request: request)
        case .containerEdit(let id): ContainerEditSheet(id: id)
        case .itemEdit(let id): ItemEditSheet(id: id)
        case .move(let itemId, let filing, let request): MoveSheet(itemId: itemId, filing: filing, request: request)
        }
    }
}

private struct CoverRouteScreen: View {
    let route: CoverRoute

    var body: some View {
        switch route {
        case .capture(let capture, let request): CaptureScreen(route: capture, request: request)
        case .photo(let itemId): PhotoViewerScreen(itemId: itemId)
        case .linkSticker(let containerId): LinkStickerScreen(containerId: containerId)
        }
    }
}

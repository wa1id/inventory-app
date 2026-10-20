import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryServices
import InventoryStrings

/// The Add sheet (06 §10, 07 §3.1). It draws its own Cancel (which asks before throwing the draft
/// away), so the shell adds none. `AddSheetModel.Routing` maps to the router:
/// `close` → `router.close(address)`, `replaceWithCapture` → `router.replaceModal(containing:with:)`
/// with `.cover(.capture(…, request: nil))`, `takePhoto` → `router.presentForResult` with
/// `.cover(.capture(…, request: $0))`, `isFocused` → `router.isFocused(address)`. Set
/// `.interactiveDismissDisabled(model.interactiveDismissDisabled || model.isPickingPlace)`.
/// Placeholder: the screen wave replaces the body.
struct AddSheet: View {
    let params: AddParams

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    init(params: AddParams) {
        self.params = params
    }

    var body: some View {
        let place = params.containerId ?? DropZone.containerId
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.Add.title, systemImage: "plus") {
                Button(L10n.Add.addPhoto) {
                    Task {
                        _ = await app.router.presentForResult(StoredImage.self) {
                            .cover(.capture(CaptureRoute(containerId: place), request: $0))
                        }
                    }
                }
                Button(L10n.Add.snapSeveral) {
                    if let address {
                        app.router.replaceModal(containing: address, with: .cover(.capture(CaptureRoute(containerId: place, mode: .fast), request: nil)))
                    }
                }
                .accessibilityIdentifier("item-snap-several")
                Button(L10n.ContainerForm.newTitle) { app.router.present(.containerNew(spaceId: DropZone.spaceId, request: nil)) }
            }
        } bottomBar: {
            BottomBar(primaryFit: true) {
                LoadingButton(label: L10n.Add.saveAndAnother, variant: .secondary, fullWidth: true) {}
            } primary: {
                LoadingButton(label: L10n.Add.save, fullWidth: true) {
                    if let address { app.router.close(address) }
                }
            }
        }
        .navigationTitle(L10n.Add.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.Common.cancel) {
                    if let address { app.router.close(address) }
                }
                .accessibilityIdentifier("item-cancel")
            }
        }
        .accessibilityIdentifier("screen-add")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { AddSheet(params: AddParams()) } }
}

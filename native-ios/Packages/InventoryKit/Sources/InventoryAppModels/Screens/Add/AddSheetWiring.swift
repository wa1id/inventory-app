import Foundation
import InventoryCore
import InventoryServices

// The Add sheet on the app: its model built from the container's stores and services, and its
// camera and navigation on the router (06 §10, 05 §3 rows 5-8). The SwiftUI sheet only draws.

extension AddSheetModel.Routing {
    /// The Add sheet's routing on `router`, for the sheet at `address` (RN `app/item/new.tsx`
    /// navigation calls; UI-KIT §1.7):
    ///
    /// - `isFocused`: whether the sheet is the screen in front (`navigation.isFocused()`);
    /// - `close`: dismisses the sheet (`router.back()`);
    /// - `replaceWithCapture`: replaces the sheet with the camera in its place
    ///   (`router.replace('/capture?…')`), Quick Snap's fast mode for "Snap several at once…",
    ///   else the default single mode with nobody waiting ("Save and add another" after a photo),
    ///   whose shot opens a fresh Add sheet;
    /// - `takePhoto`: the single-mode camera as a cover over the sheet, waiting for its photo
    ///   (`openForResult<PhotoResult>`); nil when it closes without one.
    ///
    /// Without an address (a preview outside the shell) the sheet counts as in front and does
    /// not navigate.
    public static func router(_ router: Router, address: ScreenAddress?) -> AddSheetModel.Routing {
        AddSheetModel.Routing(
            isFocused: {
                guard let address else { return true }
                return router.isFocused(address)
            },
            close: {
                guard let address else { return }
                router.close(address)
            },
            replaceWithCapture: { containerId, fast in
                guard let address else { return }
                router.replaceModal(containing: address, with: AddSheetRoutes.capture(containerId: containerId, fast: fast))
            },
            takePhoto: { containerId in
                await router.presentForResult(StoredImage.self) { request in
                    AddSheetRoutes.photo(containerId: containerId, request: request)
                }
            }
        )
    }
}

/// The routes the Add sheet opens (05 §3).
public enum AddSheetRoutes {
    /// The camera that replaces the sheet: fast for "Snap several at once…"
    /// (`/capture?containerId&mode=fast`), else single with no request ("Save and add another"
    /// after a photo, `/capture?containerId`).
    public static func capture(containerId: String, fast: Bool) -> ModalRoute {
        .cover(.capture(CaptureRoute(containerId: containerId, mode: fast ? .fast : .single), request: nil))
    }

    /// The camera for this sheet's photo (`/capture?containerId&mode=single&request`).
    public static func photo(containerId: String, request: RouteRequest<StoredImage>) -> ModalRoute {
        .cover(.capture(CaptureRoute(containerId: containerId, mode: .single), request: request))
    }
}

extension AppContainer {
    /// The Add sheet's model for the sheet at `address`, wired to the app: the current
    /// repositories (local or the household's), the one draft store, the image store, photo
    /// recognition, this phone's recent places and categories, the database as invalidator, the
    /// toasts, the platform's confirmations and haptics, the router (``AddSheetModel/Routing/router(_:address:)``),
    /// telemetry and the clock. Build it once per sheet.
    public func makeAddSheetModel(params: AddParams, address: ScreenAddress?) -> AddSheetModel {
        AddSheetModel(
            params: params,
            spaces: repositories.spaces,
            containers: repositories.containers,
            items: repositories.items,
            drafts: drafts,
            photos: imageStore,
            recognize: recognize,
            recentPlaces: recentPlaces,
            categories: categories,
            invalidator: database,
            toasts: toasts,
            confirm: platform.confirm,
            haptics: platform.haptics,
            routing: .router(router, address: address),
            telemetry: telemetry,
            now: now
        )
    }
}

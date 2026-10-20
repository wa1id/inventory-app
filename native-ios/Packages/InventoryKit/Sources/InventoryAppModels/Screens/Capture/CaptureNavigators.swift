import InventoryCore
import InventoryServices

/// Where the camera goes when it leaves, on the router (05 §3 "Exits from the camera").
///
/// The camera is a full-screen cover; RN's "replace" transitions become router replacements of
/// that cover, and the review is pushed inside it:
/// - ``CaptureNavigation/back`` closes the cover (✕, Done with no shots, a delivered request
///   photo, Type it instead in request mode);
/// - ``CaptureNavigation/addItem(containerId:photo:)`` replaces the cover with the Add sheet, with
///   the stored photo or without one (RN `router.replace('/item/new?…')`);
/// - ``CaptureNavigation/review(_:)`` pushes the review over the camera, in the same cover.
///
/// RN replaced the camera with the review, so the iOS edge swipe on the review landed on the
/// screen the set started from, without `fast_review_done` or the Done toast (05 §3, Q13). Here
/// the closed camera sits under the review, so when the review is popped while the camera is
/// still there, the camera's cover closes too: the swipe still lands on the origin.
@MainActor
public struct CaptureNavigator: Sendable {
    public let router: Router
    /// The camera's own place: a cover's root.
    public let address: ScreenAddress

    public init(router: Router, address: ScreenAddress) {
        self.router = router
        self.address = address
    }

    public func navigate(_ navigation: CaptureNavigation) {
        switch navigation {
        case .back:
            router.close(address)
        case .addItem(let containerId, let photo):
            let params = photo.map { AddParams(containerId: containerId, photo: $0) } ?? AddParams(containerId: containerId)
            replaceCamera(with: .sheet(.addItem(params)))
        case .review(let route):
            openReview(route)
        }
    }

    /// Swaps the camera's cover for `route`; should anything ever sit over the camera, the
    /// camera closes with it and `route` is presented in its place.
    private func replaceCamera(with route: ModalRoute) {
        guard router.replaceModal(containing: address, with: route) == nil else { return }
        router.close(address)
        router.present(route)
    }

    private func openReview(_ route: QuickSnapReviewRoute) {
        let review = router.push(.quickSnapReview(route))
        let router = router
        let camera = address
        router.onRemoval(of: review.address) {
            // Done and Keep shooting take the camera away with the review; only a pop (the swipe
            // back) leaves the closed camera showing.
            guard router.state.addresses.contains(camera) else { return }
            router.close(camera)
        }
    }
}

/// Where the Quick Snap review goes, on the router (05 §6.5).
///
/// - ``QuickSnapReviewNavigation/leave(containerId:)``: back to where the set started, which is
///   under the camera's cover (RN `router.canGoBack() ? router.back() : openContainer(id)`);
/// - Keep shooting and Try again replace the cover with a new camera (RN `router.replace`);
/// - a row pushes the item screen, a filing run for the drop zone;
/// - the Done toast's View goes to the Drop zone tab.
@MainActor
public struct QuickSnapReviewNavigator: Sendable {
    public let router: Router
    /// The review's own place: pushed inside the camera's cover.
    public let address: ScreenAddress

    public init(router: Router, address: ScreenAddress) {
        self.router = router
        self.address = address
    }

    public func navigate(_ navigation: QuickSnapReviewNavigation) {
        switch navigation {
        case .leave(let containerId):
            if let level = router.state.modalLevel(containing: address) {
                router.close(router.modals[level].address)
            } else if case .push = address, router.state.position(of: address) != nil {
                router.close(address)
            } else {
                router.openContainer(containerId)
            }
        case .keepShooting(let route), .tryAgain(let route):
            let camera = ModalRoute.cover(.capture(route, request: nil))
            guard router.replaceModal(containing: address, with: camera) == nil else { return }
            router.close(address)
            router.present(camera)
        case .openItem(let id, let filing):
            router.push(.item(id: id, filing: filing))
        case .viewDropZone:
            router.goToTab(.dropZone)
        }
    }
}

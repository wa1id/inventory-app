import SwiftUI
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The item's photo, full screen, opened from the thumbnail on the item screen (RN
/// app/item/[id]/photo.tsx, 05 §13).
///
/// A dark backdrop with the picture fitted inside the safe area. Pinch zooms from 1× to 4× with
/// the picture centred and a bounce at the limits; a zoomed picture pans. Close with the glass
/// button at the top leading corner, VoiceOver's escape gesture, or a downward swipe while not
/// zoomed in (``PhotoViewerGesture``: the picture follows the finger, more than 80 pt closes,
/// less settles back). It fades in and out, as RN's `animation: 'fade'` did: the cover is clear,
/// ``present(itemId:router:)`` asks for it without its slide, and the screen fades itself in once
/// the presentation has finished (so a slide, if UIKit runs one anyway, moves nothing visible)
/// and out before it closes.
///
/// The logic is ``PhotoViewerModel`` (package).
struct PhotoViewerScreen: View {
    let itemId: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.photoPathResolver) private var resolver
    @State private var model: PhotoViewerModel?
    @State private var picture: ItemPhotoPicture?
    @State private var drag: CGFloat = 0
    @State private var shown = false
    @State private var closing = false

    /// The fade in and out.
    private static let fade: Animation = .easeOut(duration: 0.25)

    init(itemId: String) {
        self.itemId = itemId
    }

    /// Opens the viewer over everything, without the cover's slide: the screen fades itself in.
    @MainActor
    static func present(itemId: String, router: Router) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.present(.photo(itemId: itemId))
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()
            if let model {
                // The read is driven from a view that is always there: the stage is empty while
                // it waits for the spinner, and an empty view never appears.
                Color.clear
                    .allowsHitTesting(false)
                    .inventoryQuery(model)
                stage(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: drag)
            }
            CameraGlassIconButton(systemImage: Glyph.close.systemName, label: L10n.Photo.close, identifier: "photo-close") {
                close()
            }
            .padding(.leading, 8)
            .padding(.top, 8)
        }
        .opacity(shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
        .presentationBackground(.clear)
        .accessibilityAction(.escape) { close() }
        // A container, so the screen's identifier does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-photo")
        .background(ItemPresentationFinished { fadeIn() })
        .onAppear {
            if model == nil {
                model = PhotoViewerModel(itemId: itemId, items: app.repositories.items, revision: app.database.revision, clock: app.clock)
            }
        }
        .task {
            // Never left invisible if UIKit does not report the presentation's end.
            try? await Task.sleep(for: .milliseconds(700))
            fadeIn()
        }
    }

    @ViewBuilder
    private func stage(_ model: PhotoViewerModel) -> some View {
        switch model.phase {
        case .failed(let title, let body):
            ItemStateScroll {
                ErrorStateView(cause: nil, subject: .item, title: title, body: body, onRetry: { model.retry() })
            }
        case .loading:
            if model.spinner.value {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        case .gone:
            ItemStateScroll {
                ErrorStateView(cause: .gone, subject: .item)
            }
        case .missing:
            ItemStateScroll {
                ContentUnavailableView {
                    Label(L10n.Errors.Photo.title, glyph: .photo)
                } description: {
                    Text(verbatim: L10n.Errors.Photo.body)
                }
                .announcesOnChange(L10n.Errors.Photo.title)
            }
        case .photo(let uri):
            Group {
                if let picture, picture.uri == uri {
                    ItemPhotoZoomView(
                        image: picture.image,
                        accessibilityLabel: model.accessibilityLabel,
                        onDrag: { dy in drag = dy },
                        onDragEnd: { dy in dragEnded(dy) }
                    )
                } else {
                    Color.clear
                }
            }
            .task(id: uri) { await load(uri, into: model) }
        }
    }

    /// Decodes the stored photo off the main actor; a file that cannot be read says the photo is
    /// missing.
    private func load(_ uri: String, into model: PhotoViewerModel) async {
        guard picture?.uri != uri else { return }
        guard let url = resolver.resolve(uri) else {
            model.imageFailed(uri)
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            // The whole picture (stored photos are at most 1400 px), so zooming in stays sharp.
            ThumbnailLoader.decode(url, minimumPixelSize: 4096)
        }.value
        guard !Task.isCancelled else { return }
        if let decoded {
            picture = ItemPhotoPicture(uri: uri, image: UIImage(cgImage: decoded.cgImage))
        } else {
            model.imageFailed(uri)
        }
    }

    private func dragEnded(_ dy: CGFloat) {
        if PhotoViewerGesture.closes(afterDrag: Double(dy)) {
            close()
            return
        }
        let settle = Motion.Easing.settle
        let ms = PhotoViewerGesture.settleMilliseconds(reduceMotion: reduceMotion)
        withAnimation(ms == 0 ? nil : .timingCurve(settle.x1, settle.y1, settle.x2, settle.y2, duration: Double(ms) / 1000)) {
            drag = 0
        }
    }

    private func fadeIn() {
        guard !shown, !closing else { return }
        withAnimation(Self.fade) { shown = true }
    }

    /// Fades out, then closes without the cover's slide.
    private func close() {
        guard !closing, let address else { return }
        closing = true
        let router = app.router
        withAnimation(Self.fade) {
            shown = false
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                router.close(address)
            }
        }
    }
}

extension PhotoViewerModel: ShellFocusDriven {}

/// Calls `action` once, when the screen's presentation has finished: at once when it was not
/// animated, after the slide when it was.
private struct ItemPresentationFinished: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(action: action)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.action = action
    }

    final class Controller: UIViewController {
        var action: @MainActor () -> Void
        private var fired = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !fired else { return }
            fired = true
            action()
        }
    }
}

/// A decoded photo and the stored URI it came from.
struct ItemPhotoPicture {
    let uri: String
    let image: UIImage
}

/// The zoomable picture: a `UIScrollView` (pinch 1…4×, centred, bounce on zoom, pan when zoomed)
/// with the swipe-down drag, which UIKit's scroll view gestures leave alone only when not zoomed
/// in (RN `ScrollView maximumZoomScale={4} centerContent bouncesZoom`).
struct ItemPhotoZoomView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    /// The picture follows a downward drag by this much.
    let onDrag: (CGFloat) -> Void
    /// The finger lifted (or the drag was cancelled, 0) this far down.
    let onDragEnd: (CGFloat) -> Void

    func makeUIView(context: Context) -> ItemPhotoZoomScrollView {
        ItemPhotoZoomScrollView()
    }

    func updateUIView(_ view: ItemPhotoZoomScrollView, context: Context) {
        view.show(image)
        view.imageView.accessibilityLabel = accessibilityLabel
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
    }
}

/// The scroll view behind ``ItemPhotoZoomView``.
final class ItemPhotoZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    private let dismissPan = UIPanGestureRecognizer()
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: (CGFloat) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bounces = false
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        decelerationRate = .fast

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIgnoresInvertColors = true
        imageView.accessibilityIdentifier = "photo-image"
        addSubview(imageView)

        dismissPan.addTarget(self, action: #selector(dismissPanned(_:)))
        dismissPan.delegate = self
        dismissPan.maximumNumberOfTouches = 1
        addGestureRecognizer(dismissPan)
        // The scroll view pans only once the swipe-down has declined the touch (it does at once
        // when zoomed in, or for anything but a clearly downward one-finger drag).
        panGestureRecognizer.require(toFail: dismissPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
    }

    /// Keeps a picture smaller than the view in its middle (RN `centerContent`).
    private func centre() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === dismissPan else { return super.gestureRecognizerShouldBegin(recognizer) }
        let moved = dismissPan.translation(in: self)
        return PhotoViewerGesture.takesDrag(
            zoomScale: Double(zoomScale),
            touches: dismissPan.numberOfTouches,
            dx: Double(moved.x),
            dy: Double(moved.y)
        )
    }

    @objc private func dismissPanned(_ recognizer: UIPanGestureRecognizer) {
        let dy = recognizer.translation(in: self).y
        switch recognizer.state {
        case .changed:
            onDrag(CGFloat(PhotoViewerGesture.offset(forDrag: Double(dy))))
        case .ended:
            onDragEnd(dy)
        case .cancelled, .failed:
            onDragEnd(0)
        default:
            break
        }
    }
}

#if DEBUG
#Preview("Photo") {
    ShellPreviewHost {
        NavigationStack { PhotoViewerPreviewRoute(name: "Cordless drill") }
    }
}

#Preview("No photo") {
    ShellPreviewHost {
        NavigationStack { PhotoViewerPreviewRoute(name: "Screwdriver set") }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { PhotoViewerScreen(itemId: "missing") }
    }
}

/// Finds a seeded item by name and shows its photo.
private struct PhotoViewerPreviewRoute: View {
    let name: String
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        Group {
            if let id { PhotoViewerScreen(itemId: id) }
        }
        .task {
            let items = (try? await app.repositories.items.listRecent(limit: 100)) ?? []
            id = items.first { $0.name == name }?.id
        }
    }
}
#endif

import SwiftUI
import Testing
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryStrings
@testable import Inventory

/// What the components announce, recorded instead of spoken.
@MainActor
final class ComponentsAnnouncementRecorder {
    private(set) var posts: [(text: String, queued: Bool)] = []

    var texts: [String] { posts.map(\.text) }

    var poster: @MainActor @Sendable (String, Bool) -> Void {
        { [weak self] text, queued in self?.posts.append((text, queued)) }
    }
}

/// Words a hosted probe changes while it is on screen.
@MainActor
@Observable
final class ComponentsProbeWords {
    var message = "Check the connection and try again."
    var error: String?
}

/// A banner at the top of a long list, the way Home and the item screen hold their notices.
private struct ComponentsBannerListProbe: View {
    let words: ComponentsProbeWords

    var body: some View {
        List {
            BannerView(tone: .warning, title: "Not saved", message: words.message, chrome: .row)
            ForEach(0..<120, id: \.self) { index in
                Text(verbatim: "Row \(index)")
            }
        }
    }
}

/// A field whose error comes and goes.
private struct ComponentsFieldErrorProbe: View {
    let words: ComponentsProbeWords
    @State private var text = ""

    var body: some View {
        Form {
            LabeledTextField(label: "Name", text: $text, error: words.error, isRequired: true)
        }
    }
}

/// Runs the main run loop for a while, so SwiftUI lays out, appears views and runs their tasks.
@MainActor
private func componentsPump(_ seconds: TimeInterval = 0.4) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

/// Announcements (08 §9.2 item 10): a notice is announced when it appears and when its words
/// change, never again because a list row scrolled back into view.
@MainActor
@Suite("Components announcements")
struct ComponentsAnnouncementTests {
    @Test("a banner in a list row is announced once, not again after scrolling away and back")
    func bannerScrolledAwayAndBack() async throws {
        let recorder = ComponentsAnnouncementRecorder()
        let words = ComponentsProbeWords()
        let host = try ShellTestWindow(
            ComponentsBannerListProbe(words: words).environment(\.componentAnnounce, recorder.poster)
        )
        defer { host.close() }
        await ShellTestWait.until("the banner's first announcement") { recorder.posts.count == 1 }
        #expect(recorder.texts == ["Not saved. Check the connection and try again."])

        let scroll = try #require(host.window.rootViewController?.view.shellDescendants.compactMap { $0 as? UIScrollView }.first)
        for _ in 0..<2 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            scroll.layoutIfNeeded()
            await componentsPump()
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            scroll.layoutIfNeeded()
            await componentsPump()
        }
        #expect(recorder.posts.count == 1, "\(recorder.texts)")

        words.message = "Still not saved."
        await ShellTestWait.until("the changed words' announcement") { recorder.posts.count == 2 }
        #expect(recorder.texts.last == "Not saved. Still not saved.")
        #expect(recorder.posts.allSatisfy { !$0.queued })
    }

    @Test("a field error is announced queued, and again when it comes back after being cleared")
    func fieldErrorComesBack() async throws {
        let recorder = ComponentsAnnouncementRecorder()
        let words = ComponentsProbeWords()
        words.error = "Give it a name."
        let host = try ShellTestWindow(
            ComponentsFieldErrorProbe(words: words).environment(\.componentAnnounce, recorder.poster)
        )
        defer { host.close() }
        let spoken = TextFieldCopy.errorAnnouncement("Give it a name.")
        await ShellTestWait.until("the error's announcement") { recorder.posts.count == 1 }
        #expect(recorder.posts.first?.text == spoken)
        #expect(recorder.posts.first?.queued == true)

        words.error = nil
        await componentsPump()
        #expect(recorder.posts.count == 1)
        words.error = "Give it a name."
        await ShellTestWait.until("the error announced again") { recorder.posts.count == 2 }
        #expect(recorder.texts == [spoken, spoken])
    }
}

/// Lays out one view at a width and reports where its marked pieces landed.
@MainActor
private enum ComponentsLayoutProbe {
    /// The size the view asks for at `width` (nil: its ideal size).
    static func size<V: View>(_ view: V, width: CGFloat?) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    /// Hosts `view` framed to `width` in a window and returns the frames of the pieces marked with
    /// `.componentsProbe(_:)`, in the view's own coordinates.
    static func frames<V: View>(_ view: V, width: CGFloat) async throws -> [String: CGRect] {
        let box = ComponentsProbeFrames()
        let root = view
            .frame(width: width, alignment: .topLeading)
            .coordinateSpace(.named(ComponentsProbeFrames.space))
            .environment(\.componentsProbeFrames, box)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let host = try ShellTestWindow(root)
        defer { host.close() }
        await componentsPump(0.3)
        return box.frames
    }
}

@MainActor
private final class ComponentsProbeFrames {
    static let space = "components-probe"
    var frames: [String: CGRect] = [:]
}

private extension EnvironmentValues {
    @Entry var componentsProbeFrames: ComponentsProbeFrames?
}

private struct ComponentsProbeMark: ViewModifier {
    let name: String
    @Environment(\.componentsProbeFrames) private var box

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ComponentsProbeFrames.space)) } action: { frame in
            box?.frames[name] = frame
        }
    }
}

private extension View {
    func componentsProbe(_ name: String) -> some View {
        modifier(ComponentsProbeMark(name: name))
    }
}

/// The location line's wrapping row: what it measures is what it draws.
@MainActor
@Suite("Components wrapping layout")
struct ComponentsWrappingLayoutTests {
    private static var location: some View {
        WrappingHStack(horizontalSpacing: 6, verticalSpacing: 2) {
            Text(verbatim: "Garage").textRole(.where).componentsProbe("space")
            Text(verbatim: "›").textRole(.where)
            Text(verbatim: "Tool chest").textRole(.where)
            Tape(code: "CAB-J92R").componentsProbe("tape")
        }
    }

    @Test("a line placed a fraction of a point narrower than it measured stays one line")
    func pixelRoundedWidthStaysOneLine() async throws {
        let ideal = ComponentsLayoutProbe.size(Self.location, width: nil)
        #expect(ideal.width > 0 && ideal.height > 0)
        // What a parent hands back after rounding the measured width to the 3x pixel grid.
        let rounded = (ideal.width * 3).rounded(.down) / 3 - 0.2
        let measured = ComponentsLayoutProbe.size(Self.location, width: rounded)
        #expect(abs(measured.height - ideal.height) < 0.5, "measured \(measured) at \(rounded), ideal \(ideal)")

        let frames = try await ComponentsLayoutProbe.frames(Self.location, width: rounded)
        let space = try #require(frames["space"]), tape = try #require(frames["tape"])
        // Drawn on the line it was measured on: the tape sits beside the words, not under them.
        #expect(tape.minY < space.maxY, "space \(space), tape \(tape)")
        #expect(tape.maxY <= measured.height + 0.5, "tape \(tape) outside the measured \(measured)")
    }

    @Test("a line that really does not fit still wraps, the tape whole on the next line")
    func realOverflowWraps() async throws {
        let ideal = ComponentsLayoutProbe.size(Self.location, width: nil)
        let narrow = ideal.width - 30
        let measured = ComponentsLayoutProbe.size(Self.location, width: narrow)
        #expect(measured.height > ideal.height + 4)
        let frames = try await ComponentsLayoutProbe.frames(Self.location, width: narrow)
        let space = try #require(frames["space"]), tape = try #require(frames["tape"])
        #expect(tape.minY >= space.maxY, "space \(space), tape \(tape)")
        #expect(tape.maxY <= measured.height + 0.5, "tape \(tape) outside the measured \(measured)")
    }

    @Test("fit or stack: side by side when both fit, the second under the first when not")
    func fitOrStack() async throws {
        let pair = ComponentFitOrStack(horizontalSpacing: 12, verticalSpacing: 12) {
            Text(verbatim: "CAB-J92R").componentsProbe("lead")
            Text(verbatim: "Move…").componentsProbe("action")
        }
        let wide = try await ComponentsLayoutProbe.frames(pair, width: 360)
        let lead = try #require(wide["lead"]), action = try #require(wide["action"])
        #expect(abs(lead.midY - action.midY) < 1)
        #expect(abs(action.maxX - 360) < 1, "the action sits at the trailing edge: \(action)")

        let narrowWidth = lead.width + action.width
        let narrow = try await ComponentsLayoutProbe.frames(pair, width: narrowWidth)
        let stackedLead = try #require(narrow["lead"]), stackedAction = try #require(narrow["action"])
        #expect(stackedAction.minY >= stackedLead.maxY + 11)
        #expect(abs(stackedAction.minX) < 1, "stacked at the leading edge: \(stackedAction)")
    }
}

/// Reduce Motion in the shared animations (08 §8.3): every motion is nil or zero.
@MainActor
@Suite("Components motion")
struct ComponentsMotionTests {
    @Test("Reduce Motion turns every component animation off")
    func reduced() {
        #expect(ComponentMotion.expand(reduceMotion: true) == nil)
        #expect(ComponentMotion.toastIn(reduceMotion: true) == nil)
        #expect(ComponentMotion.toastOut(reduceMotion: true) == nil)
        #expect(ComponentMotion.toastSettle(reduceMotion: true) == nil)
        #expect(ComponentMotion.toastRise(reduceMotion: true) == 0)
    }

    @Test("without it they keep RN's lengths and curves")
    func full() {
        #expect(ComponentMotion.expand(reduceMotion: false) == .easeInOut(duration: 0.18))
        #expect(ComponentMotion.toastIn(reduceMotion: false) == .timingCurve(Motion.Easing.out.x1, Motion.Easing.out.y1, Motion.Easing.out.x2, Motion.Easing.out.y2, duration: 0.16))
        #expect(ComponentMotion.toastOut(reduceMotion: false) == .timingCurve(Motion.Easing.exit.x1, Motion.Easing.exit.y1, Motion.Easing.exit.x2, Motion.Easing.exit.y2, duration: 0.12))
        #expect(ComponentMotion.toastSettle(reduceMotion: false) != nil)
        #expect(ComponentMotion.toastRise(reduceMotion: false) == 8)
        #expect(ComponentMotion.curve(Motion.Easing.settle, ms: 0) == nil)
    }
}

/// The custom colours against WCAG AA in both schemes (08 §4.5, §11).
@MainActor
@Suite("Components colour contrast")
struct ComponentsContrastTests {
    private static func hex(_ color: UIColor, dark: Bool) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(alpha > 0.99, "the colour is opaque")
        return HexColor.toHex(Double(red) * 255, Double(green) * 255, Double(blue) * 255)
    }

    @Test("signal text keeps 4.5:1 on the cells, the page and its wash", arguments: [false, true])
    func signal(dark: Bool) {
        let signal = Self.hex(UIColor(DesignColor.signal), dark: dark)
        let surfaces: [UIColor] = [.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground, UIColor(DesignColor.signalWash)]
        for surface in surfaces {
            let background = Self.hex(surface, dark: dark)
            let ratio = HexColor.contrast(signal, background)
            #expect(ratio >= 4.5, "\(signal) on \(background): \(ratio)")
        }
    }

    @Test("the RN signal tokens, light and dark")
    func tokens() {
        #expect(Self.hex(UIColor(DesignColor.signal), dark: false) == "#B3361A")
        #expect(Self.hex(UIColor(DesignColor.signal), dark: true) == "#FF9573")
        #expect(Self.hex(UIColor(DesignColor.signalWash), dark: false) == "#FBECE7")
        #expect(Self.hex(UIColor(DesignColor.signalWash), dark: true) == "#3A231C")
    }

    @Test("tape ink on tape yellow, and search matches, read in both schemes", arguments: [false, true])
    func brand(dark: Bool) {
        let tape = Self.hex(UIColor(named: "Tape") ?? .yellow, dark: dark)
        let ink = Self.hex(UIColor(named: "TapeInk") ?? .black, dark: dark)
        #expect(HexColor.contrast(ink, tape) >= 4.5)
        let mark = Self.hex(UIColor(named: "SearchMark") ?? .yellow, dark: dark)
        let label = Self.hex(.label, dark: dark)
        #expect(HexColor.contrast(label, mark) >= 4.5)
    }
}

/// Collects every accessibility node's identifier, containers included.
@MainActor
private enum ComponentsAccessibilityTree {
    static func identifiers(in view: UIView) -> [String] {
        var found: [String] = []
        collect(view, into: &found, depth: 0)
        return found
    }

    private static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func collect(_ object: Any, into found: inout [String], depth: Int) {
        guard depth < 60, let object = object as? NSObject else { return }
        if let identifier = identifier(of: object), !identifier.isEmpty { found.append(identifier) }
        if let children = object.accessibilityElements, !children.isEmpty {
            for child in children { collect(child, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { collect(child, into: &found, depth: depth + 1) }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }
}

/// Identifiers and targets the wave-6 pass restored.
@MainActor
@Suite("Components identifiers and targets")
struct ComponentsIdentifierTests {
    private static func identifiers<V: View>(_ view: V) async throws -> [String] {
        _ = ComponentsHost.render(EmptyView())  // switches the automation mode on
        let host = try ShellTestWindow(view)
        defer { host.close() }
        await componentsPump(0.3)
        return try ComponentsAccessibilityTree.identifiers(in: #require(host.window.rootViewController?.view))
    }

    @Test("a search hit keeps RN's place-row wrapper around the row's own identifier")
    func placeRowWrapper() async throws {
        let spaces = Dictionary(uniqueKeysWithValues: ComponentsFixtures.spaces.map { ($0.id, $0) })
        let containers = Dictionary(uniqueKeysWithValues: ComponentsFixtures.containers.map { ($0.id, $0) })
        let found = try await Self.identifiers(List {
            PlaceRow(hit: LocationSearchResult(kind: .space, id: "s-garage", title: "Garage", subtitle: "", spaceId: "s-garage", itemCount: 12), spaces: spaces, containers: containers, onPress: {})
            PlaceRow(hit: LocationSearchResult(kind: .container, id: "c-drawer", title: "", subtitle: "", spaceId: "s-garage", itemCount: 1), spaces: spaces, containers: containers, onPress: {})
        })
        #expect(found.contains(PlaceRowText.placeIdentifier("s-garage")), "\(found)")
        #expect(found.contains(PlaceRowText.spaceIdentifier("s-garage")), "\(found)")
        #expect(found.contains(PlaceRowText.placeIdentifier("c-drawer")), "\(found)")
        #expect(found.contains(PlaceRowText.containerIdentifier("c-drawer")), "\(found)")
    }

    @Test("an empty state's own identifier leaves its button's identifier reachable")
    func emptyStateContains() async throws {
        let found = try await Self.identifiers(List {
            EmptyStateView(
                title: L10n.Picker.None.title,
                message: L10n.Picker.None.body,
                glyph: .box,
                primary: StateAction(label: L10n.Picker.None.action, identifier: "move-no-containers") {},
                identifier: "picker-empty"
            )
        })
        #expect(found.contains("picker-empty"), "\(found)")
        #expect(found.contains("move-no-containers"), "\(found)")
    }

    @Test("a quiet button is at least 44 points tall and wide", arguments: [ButtonSize.small, .regular])
    func quietTarget(size: ButtonSize) {
        let quiet = ComponentsHost.render(LoadingButton(label: "Not now", variant: .quiet, size: size, action: {}).fixedSize())
        #expect(quiet.size.height >= DesignMetrics.minTouchTarget, "\(quiet.size)")
        let short = ComponentsHost.render(LoadingButton(label: "OK", variant: .destructive, size: size, action: {}).fixedSize())
        #expect(short.size.width >= DesignMetrics.minTouchTarget, "\(short.size)")
    }
}

/// Pinned chrome stays a part of the screen at the largest text sizes.
@MainActor
@Suite("Components chrome at the largest sizes")
struct ComponentsChromeSizeTests {
    private static let window = CGSize(width: 393, height: 852)

    @Test("a camera notice's words scroll inside it, so it takes at most part of the window")
    func cameraPanelCapped() {
        let long = String(repeating: "The label could not be read because the camera did not start. ", count: 6)
        let panel = CameraPanel(
            tone: .error,
            title: L10n.Scan.invalidTitle,
            message: long,
            actions: [
                CameraPanelAction(id: "again", label: L10n.Scan.scanAgain) {},
                CameraPanelAction(id: "type", label: L10n.Scan.typeCode, systemImage: "keyboard") {},
            ]
        )
        .environment(\.shellWindowSize, Self.window)
        let rendered = ComponentsHost.render(panel, width: Self.window.width - 32, appearance: .init(scheme: .dark, size: .accessibility5), settle: 0.3)
        #expect(rendered.size.height <= Self.window.height * 0.6, "\(rendered.size)")
        #expect(rendered.element(identifier: "again") != nil, "\(rendered.dump)")
        #expect(rendered.element(identifier: "type") != nil, "\(rendered.dump)")
    }

    @Test("two stacked bottom-bar buttons take at most a quarter of the window")
    func bottomBarCapped() {
        let app = AppContainer.preview(seed: false)
        let bar = BottomBar {
            LoadingButton(label: L10n.Common.notNow, variant: .secondary, fullWidth: true) {}
        } primary: {
            LoadingButton(label: L10n.Join.submit, fullWidth: true) {}
        }
        .environment(app)
        .environment(\.shellWindowSize, Self.window)
        let rendered = ComponentsHost.render(bar, width: Self.window.width, appearance: .init(scheme: .light, size: .accessibility5))
        #expect(rendered.size.height <= Self.window.height / 4, "\(rendered.size)")
        #expect(BottomBar<EmptyView, EmptyView>.maximumTextSize == .xxxLarge)
    }
}

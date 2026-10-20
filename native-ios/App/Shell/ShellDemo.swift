#if DEBUG
import Foundation
import OSLog
import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings

/// Debug builds only: launch arguments that put the shell in a state for screenshots, since the
/// simulator cannot be tapped from a script. `docs/UI-KIT.md` ("Screen foundation") lists the
/// seeded names the route specs can use.
///
/// - `-demo YES`: the sample inventory in memory (nothing on the device is read or written);
///   `-demoOnboarding YES` starts on onboarding; `-demoSeed empty` starts with an empty
///   inventory (onboarding done).
/// - `-demoHousehold offline|revoked`: joined to a household whose server is unreachable (the
///   connection banner after 2.5 s) or answers 401 (the removed-phone layer).
/// - `-demoArea <area> -demoState <state>`: the area's own hook (`<Area>Demo` in
///   `App/Screens/<Area>/<Area>Demo.swift`) first makes the container (nil keeps the default
///   one), then runs once the main shell shows, after `-demoTab` and before `-demoRoute`.
///   Areas: home, account, labels, places, item, add, capture.
/// - `-demoTab spaces|scan|dropZone`: selects that tab first.
/// - `-demoRoute <spec>[><spec>…]`: opens routes once the shell shows, in order, 0.7 s apart
///   (``ShellDemoRoute``), e.g. `container:Tool_chest>containerEdit:Tool_chest`.
/// - `-demoOpen settings|label|add|addOverSheet|capture|review|move`: the wave-4 shortcuts,
///   mapped onto `-demoRoute` (``ShellDemoRoute/demoOpen(_:)``).
/// - `-demoToast info|error|action`: shows that toast last.
enum ShellDemo {
    private static var defaults: UserDefaults { .standard }
    static let log = Logger(subsystem: "com.wystudio.inventory", category: "demo")

    /// The area named by `-demoArea`, if any.
    static var area: ShellDemoArea? {
        guard let name = defaults.string(forKey: "demoArea") else { return nil }
        guard let area = ShellDemoArea(rawValue: name) else {
            let areas = ShellDemoArea.allCases.map(\.rawValue).joined(separator: ", ")
            log.error("-demoArea \(name, privacy: .public) is not an area; use one of \(areas, privacy: .public)")
            return nil
        }
        return area
    }

    /// `-demoState`, or "" when absent.
    static var state: String { defaults.string(forKey: "demoState") ?? "" }

    @MainActor
    static func makeContainer(platform: AppPlatform) -> AppContainer? {
        guard defaults.bool(forKey: "demo") else { return nil }
        if let area, let container = area.container(state: state, platform: platform) { return container }
        let household = defaults.string(forKey: "demoHousehold")
        let session = household.map { _ in
            HouseholdSession(origin: "https://box.example", token: "demo-token", deviceId: "demo-device", deviceName: "iPhone", householdName: "Home")
        }
        let transport: any HTTPTransport = household == "revoked" ? ShellDemoUnauthorizedTransport() : ShellOfflineTransport()
        return AppContainer.preview(
            platform: platform,
            seed: defaults.string(forKey: "demoSeed") != "empty",
            onboardingCompleted: !defaults.bool(forKey: "demoOnboarding"),
            householdSession: session,
            transport: transport
        )
    }

    /// Runs the requested steps, once per process.
    @MainActor
    static func run(_ app: AppContainer) async {
        guard defaults.bool(forKey: "demo"), !ran else { return }
        ran = true
        let router = app.router
        switch defaults.string(forKey: "demoTab") {
        case "spaces": router.selectTab(.spaces)
        case "scan": router.selectTab(.scan)
        case "dropZone": router.selectTab(.dropZone)
        default: break
        }
        try? await Task.sleep(for: .milliseconds(400))
        if let area { await area.run(state: state, app: app) }
        let spec = defaults.string(forKey: "demoRoute") ?? defaults.string(forKey: "demoOpen").flatMap(ShellDemoRoute.demoOpen)
        if let spec { await ShellDemoRoute.open(spec, app: app) }
        try? await Task.sleep(for: .milliseconds(700))
        switch defaults.string(forKey: "demoToast") {
        case "info":
            app.toasts.show(ToastOptions(message: L10n.Move.undone, duration: .seconds(60)))
        case "error":
            app.toasts.show(ToastOptions(message: L10n.Move.failed, tone: .error, duration: .seconds(60)))
        case "action":
            app.toasts.show(ToastOptions(
                message: L10n.Move.movedTo(container: "Tool chest", space: "Garage"),
                action: ToastAction(label: L10n.Common.undo) {},
                duration: .seconds(60)))
        default:
            break
        }
    }

    @MainActor private static var ran = false
}

/// The screen areas with demo hooks (`-demoArea`). Each area fills in its own
/// `App/Screens/<Area>/<Area>Demo.swift`; this file never changes for them.
enum ShellDemoArea: String, CaseIterable {
    case home, account, labels, places, item, add, capture

    @MainActor
    func container(state: String, platform: AppPlatform) -> AppContainer? {
        switch self {
        case .home: HomeDemo.container(state: state, platform: platform)
        case .account: AccountDemo.container(state: state, platform: platform)
        case .labels: LabelsDemo.container(state: state, platform: platform)
        case .places: PlacesDemo.container(state: state, platform: platform)
        case .item: ItemDemo.container(state: state, platform: platform)
        case .add: AddDemo.container(state: state, platform: platform)
        case .capture: CaptureDemo.container(state: state, platform: platform)
        }
    }

    @MainActor
    func run(state: String, app: AppContainer) async {
        switch self {
        case .home: await HomeDemo.run(state: state, app: app)
        case .account: await AccountDemo.run(state: state, app: app)
        case .labels: await LabelsDemo.run(state: state, app: app)
        case .places: await PlacesDemo.run(state: state, app: app)
        case .item: await ItemDemo.run(state: state, app: app)
        case .add: await AddDemo.run(state: state, app: app)
        case .capture: await CaptureDemo.run(state: state, app: app)
        }
    }
}

/// `-demoRoute`: route specs resolved against the inventory on screen (the seeded preview
/// inventory unless an area's container says otherwise).
///
/// A spec is `name` or `name:argument`; several joined with `>` open in order, 0.7 s apart.
/// Names match case-insensitively, the first match wins, and `_` in an argument stands for a
/// space (`container:Tool_chest`), since `mac.sh` splits launch arguments on spaces. A spec
/// that names nothing known is logged (`log stream --predicate 'category == "demo"'`) and
/// opens nothing; the rest still open.
///
/// | Spec | Opens |
/// |---|---|
/// | `settings`, `privacy`, `household`, `backup` | that screen, pushed |
/// | `label[:<token>]` | the label screen (no token: ``AppContainerPreviewData/unboundLabelToken``) |
/// | `space:<name>`, `container:<name or code>`, `qrLabel:<container>` | pushed |
/// | `item:<name>`, `itemFiling:<name>` | the item screen (filing: from the drop zone) |
/// | `add[:<container>]` | the Add sheet (into that container) |
/// | `spaceNew`, `spaceEdit:<name>`, `containerNew:<space>`, `containerEdit:<container>`, `itemEdit:<item>` | that sheet |
/// | `move:<item>`, `file:<item>` | the Move or File sheet |
/// | `capture[:<container>]` | the single-photo camera (the drop zone by default) |
/// | `quickSnap`, `review` | Quick Snap; the review pushed over it |
/// | `photo:<item>`, `linkSticker:<container>` | that cover |
///
/// An item named nothing is `item:` with no argument (also `move:`, `file:`, …).
enum ShellDemoRoute {
    /// One spec: its name and the text after the first `:`, if any.
    struct Step: Equatable {
        var name: String
        var argument: String?

        /// Whether opening it looks a name up in the inventory.
        var namesSomething: Bool {
            switch name.lowercased() {
            case "settings", "privacy", "household", "backup", "label", "spacenew", "quicksnap", "review": false
            case "add", "capture": argument != nil
            default: true
            }
        }
    }

    /// Splits `spec` into steps; empty steps are dropped.
    static func parse(_ spec: String) -> [Step] {
        spec.split(separator: ">", omittingEmptySubsequences: true).compactMap { part in
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            guard let colon = text.firstIndex(of: ":") else { return Step(name: text, argument: nil) }
            return Step(name: String(text[..<colon]), argument: String(text[text.index(after: colon)...]))
        }
    }

    /// The `-demoRoute` spec for a wave-4 `-demoOpen` value.
    static func demoOpen(_ value: String) -> String? {
        switch value {
        case "settings": "settings"
        case "label": "label"
        case "add": "add"
        case "addOverSheet": "add>containerNew:Garage"
        case "capture": "quickSnap"
        case "review": "review"
        case "move": "file:HDMI_cable"
        default: nil
        }
    }

    /// Opens every step of `spec` in order.
    @MainActor
    static func open(_ spec: String, app: AppContainer) async {
        let steps = parse(spec)
        for (index, step) in steps.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(700)) }
            // Only a spec that names something reads (over the household's transport when joined,
            // which can be slow), so `add` or `settings` opens at once.
            let inventory = step.namesSomething ? await ShellDemoInventory.read(app.repositories) : ShellDemoInventory()
            if !(await open(step, inventory: inventory, app: app)) {
                let text = step.argument.map { "\(step.name):\($0)" } ?? step.name
                ShellDemo.log.error("-demoRoute: \(text, privacy: .public) names nothing known; skipped")
            }
        }
    }

    /// Opens one step; false when its name or argument is unknown.
    @MainActor
    static func open(_ step: Step, inventory: ShellDemoInventory, app: AppContainer) async -> Bool {
        let router = app.router
        let argument = step.argument ?? ""
        switch step.name.lowercased() {
        case "settings": router.push(.settings)
        case "privacy": router.push(.privacy)
        case "household": router.push(.household)
        case "backup": router.push(.backup)
        case "label": router.push(.label(token: step.argument ?? AppContainerPreviewData.unboundLabelToken))
        case "space":
            guard let id = inventory.space(argument) else { return false }
            router.push(.space(id: id))
        case "container":
            guard let id = inventory.container(argument) else { return false }
            if id == DropZone.containerId { router.goToTab(.dropZone) } else { router.push(.container(id: id)) }
        case "qrlabel":
            guard let id = inventory.container(argument) else { return false }
            router.push(.qrLabel(containerId: id))
        case "item", "itemfiling":
            guard let id = inventory.item(step.argument) else { return false }
            router.push(.item(id: id, filing: step.name.lowercased() == "itemfiling"))
        case "add":
            if let name = step.argument {
                guard let id = inventory.container(name) else { return false }
                router.present(.addItem(AddParams(containerId: id)))
            } else {
                router.present(.addItem(AddParams()))
            }
        case "spacenew": router.present(.spaceNew(request: nil))
        case "spaceedit":
            guard let id = inventory.space(argument) else { return false }
            router.present(.spaceEdit(id: id))
        case "containernew":
            guard let id = inventory.space(argument) else { return false }
            router.present(.containerNew(spaceId: id, request: nil))
        case "containeredit":
            guard let id = inventory.container(argument) else { return false }
            router.present(.containerEdit(id: id))
        case "itemedit":
            guard let id = inventory.item(step.argument) else { return false }
            router.present(.itemEdit(id: id))
        case "move", "file":
            guard let id = inventory.item(step.argument) else { return false }
            router.present(.move(itemId: id, filing: step.name.lowercased() == "file", request: nil))
        case "capture":
            let containerId = step.argument.map { inventory.container($0) } ?? DropZone.containerId
            guard let containerId else { return false }
            router.present(.capture(CaptureRoute(containerId: containerId, mode: .single), request: nil))
        case "quicksnap": router.openQuickSnap()
        case "review":
            router.openQuickSnap()
            try? await Task.sleep(for: .milliseconds(700))
            router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 2)))
        case "photo":
            guard let id = inventory.item(step.argument) else { return false }
            router.present(.photo(itemId: id))
        case "linksticker":
            guard let id = inventory.container(argument) else { return false }
            router.present(.linkSticker(containerId: id))
        default:
            return false
        }
        return true
    }
}

/// What the route specs can name: the spaces, containers and items on screen now.
struct ShellDemoInventory {
    var spaces: [SpaceWithCounts] = []
    var containers: [ContainerWithSpace] = []
    var items: [ItemWithContext] = []

    /// Reads the lists; a list that fails stays empty.
    static func read(_ repositories: CurrentRepositories) async -> ShellDemoInventory {
        async let spaces = try? repositories.spaces.listWithCounts()
        async let containers = try? repositories.containers.listAllWithSpace()
        async let items = try? repositories.items.listRecent(limit: 100)
        return ShellDemoInventory(spaces: await spaces ?? [], containers: await containers ?? [], items: await items ?? [])
    }

    /// The first space with this name.
    func space(_ name: String) -> String? {
        spaces.first { Self.same($0.name, name) }?.id
    }

    /// The first container with this name, else with this short code; "Drop zone" is the drop
    /// zone's own container.
    func container(_ name: String) -> String? {
        if let match = containers.first(where: { $0.container.name.map { Self.same($0, name) } ?? false }) { return match.container.id }
        if let match = containers.first(where: { Self.same($0.container.shortCode, name) }) { return match.container.id }
        if Self.same(L10n.DropZone.title, name) || Self.same(DropZone.containerId, name) { return DropZone.containerId }
        return nil
    }

    /// The newest item with this name; nil or empty names the first unnamed one.
    func item(_ name: String?) -> String? {
        guard let name, !name.isEmpty else {
            return items.first { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }?.id
        }
        return items.first { Self.same($0.name, name) }?.id
    }

    /// Case-insensitive, with `_` in the spec standing for a space.
    static func same(_ stored: String, _ spec: String) -> Bool {
        let wanted = spec.replacingOccurrences(of: "_", with: " ")
        return stored.caseInsensitiveCompare(spec) == .orderedSame || stored.caseInsensitiveCompare(wanted) == .orderedSame
    }
}

/// Every request answered 401, as for a phone removed from the household. The answer takes
/// 1.5 s, so a route opened with `-demoRoute` is up when the removed-phone layer arrives.
private struct ShellDemoUnauthorizedTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .milliseconds(1500))
        return HTTPResponse(status: 401, headers: ["content-type": "application/json"], body: Data(#"{"error":"unauthorized"}"#.utf8))
    }
}
#endif

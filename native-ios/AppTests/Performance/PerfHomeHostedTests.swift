import Foundation
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryStorage

/// The app on the 10 000-item inventory of `-demoSeed large` (00-index M9, docs/PERFORMANCE.md),
/// hosted in a window on the simulator: from a keystroke to the results drawn on Home, typing a
/// word letter by letter, opening the 500-item container, the Move sheet's 250 containers and
/// scrolling Home's results.
///
/// Every figure is printed as a `PERF |` line (`scripts/mac.sh apptest
/// -only-testing:InventoryTests/PerfHomeHostedTests`, then grep the log). The limits only catch
/// gross regressions: they are several times the M9 budget, so a loaded Mac does not fail them.
@Suite("Perf: the app on 10 000 items (hosted)", .serialized)
@MainActor
struct PerfHomeHostedTests {
    /// Keystroke to results drawn, the 200 ms pause included. M9 asks for under a second.
    static let resultsLimit: Duration = .seconds(3)
    /// A screen's first rows drawn.
    static let screenLimit: Duration = .seconds(5)
    /// The longest the main thread may stall while she types (a frame is 16 ms; M9 asks that
    /// typing stays smooth, nothing over 100 ms).
    static let stallLimit: Duration = .seconds(1)

    @Test("from a keystroke to the results drawn, for every query class")
    func keystrokeToResults() async throws {
        let harness = try await PerfHostedHarness.start()
        defer { harness.close() }
        for query in PerfHostedQuery.allCases {
            // Back to the overview first, so every query starts from the same list.
            harness.app.home.setQuery("")
            try await Task.sleep(for: .milliseconds(300))
            let frames = PerfFrameMonitor()
            frames.start()
            let elapsed = try await harness.typeAndWaitForResults(query.rawValue)
            // The frames that draw the new rows.
            try await Task.sleep(for: .milliseconds(100))
            frames.stop()
            let results = harness.app.home.search.results
            PerfHostedReport.line("keystroke → results drawn | `\(query.rawValue)` (\(query.label)) | \(results?.items.count ?? 0) items, \(results?.locations.count ?? 0) places | \(PerfHostedReport.text(elapsed)) | longest frame \(PerfHostedReport.text(frames.longest))")
            #expect(elapsed < Self.resultsLimit, "\(query.rawValue): \(PerfHostedReport.text(elapsed))")
        }
    }

    @Test("a misspelt search shows the corrected results quickly, the first time and again")
    func misspeltSearch() async throws {
        let harness = try await PerfHostedHarness.start()
        defer { harness.close() }
        // The first search that finds nothing reads the inventory's words; later ones at the
        // same revision reuse them.
        for (pass, query, shown) in [("first", "scrwdriver", "screwdriver"), ("again", "jumpr cabels", "jumper cables")] {
            harness.app.home.setQuery("")
            try await Task.sleep(for: .milliseconds(300))
            let frames = PerfFrameMonitor()
            frames.start()
            let elapsed = try await harness.typeAndWaitForResults(query)
            try await Task.sleep(for: .milliseconds(100))
            frames.stop()
            let search = harness.app.home.search
            PerfHostedReport.line("keystroke → corrected results drawn | `\(query)` → `\(search.correction?.shown ?? "none")` (\(pass)) | \(search.results?.items.count ?? 0) items | \(PerfHostedReport.text(elapsed)) | longest frame \(PerfHostedReport.text(frames.longest))")
            #expect(search.correction?.shown == shown)
            #expect(elapsed < Self.resultsLimit, "\(query): \(PerfHostedReport.text(elapsed))")
        }
    }

    @Test("typing a word letter by letter keeps the main thread free, and ends with its results")
    func typingStaysSmooth() async throws {
        let harness = try await PerfHostedHarness.start()
        defer { harness.close() }
        let frames = PerfFrameMonitor()
        frames.start()
        var lastKeystroke = ContinuousClock.now
        for prefix in PerfHostedReport.prefixes(of: "screwdriver") {
            lastKeystroke = ContinuousClock.now
            harness.app.home.setQuery(prefix)
            // About eight keys a second.
            try await Task.sleep(for: .milliseconds(120))
        }
        await harness.waitForResults(of: "screwdriver")
        let toResults = ContinuousClock.now - lastKeystroke
        try await Task.sleep(for: .milliseconds(300))
        frames.stop()
        PerfHostedReport.line("typing `screwdriver` at 8 keys/s | last key → results drawn \(PerfHostedReport.text(toResults)) | longest frame \(PerfHostedReport.text(frames.longest)) | frames over 100 ms: \(frames.count(over: .milliseconds(100))) of \(frames.frames)")
        #expect(frames.longest < Self.stallLimit, "longest frame \(PerfHostedReport.text(frames.longest))")
        #expect(toResults < Self.resultsLimit)
    }

    @Test("the 500-item container and the Move sheet's 250 containers open quickly")
    func screensOpen() async throws {
        let harness = try await PerfHostedHarness.start()
        defer { harness.close() }
        let containers = try await harness.app.repositories.containers.listAllWithSpace()
        let big = try #require(containers.first { $0.container.name == PerfInventorySeed.bigContainerName })

        var started = ContinuousClock.now
        harness.app.router.push(.container(id: big.container.id))
        await harness.waitForList(rows: 500, description: "the container's 500 rows")
        let containerTime = ContinuousClock.now - started
        PerfHostedReport.line("open the 500-item container → rows drawn | \(PerfHostedReport.text(containerTime))")
        #expect(containerTime < Self.screenLimit)

        harness.app.router.reset()
        try await Task.sleep(for: .milliseconds(800))
        let item = try #require(try await harness.app.repositories.items.listRecent(limit: 1).first)
        started = ContinuousClock.now
        harness.app.router.present(.move(itemId: item.item.id, filing: false, request: nil))
        await harness.waitForList(rows: 250, description: "the picker's 250 containers")
        let moveTime = ContinuousClock.now - started
        PerfHostedReport.line("open the Move sheet → 250 containers drawn | \(PerfHostedReport.text(moveTime))")
        #expect(moveTime < Self.screenLimit)
        harness.app.router.dismissAll()
        try await Task.sleep(for: .milliseconds(600))
    }

    @Test("scrolling 230 results draws each screenful quickly; memory stays bounded")
    func scrollAndMemory() async throws {
        let before = PerfHostedReport.footprintMegabytes()
        let harness = try await PerfHostedHarness.start()
        defer { harness.close() }
        let afterLaunch = PerfHostedReport.footprintMegabytes()
        _ = try await harness.typeAndWaitForResults("a")
        let list = try #require(harness.homeList())
        let frames = PerfFrameMonitor()
        frames.start()
        var steps: [Duration] = []
        let page = max(200, list.bounds.height * 0.8)
        while list.contentOffset.y + list.bounds.height < list.contentSize.height - 1 {
            let started = ContinuousClock.now
            list.setContentOffset(CGPoint(x: 0, y: min(list.contentOffset.y + page, list.contentSize.height - list.bounds.height)), animated: false)
            list.layoutIfNeeded()
            steps.append(ContinuousClock.now - started)
            // A frame, so thumbnails decode and the next screenful is drawn as when scrolling.
            try await Task.sleep(for: .milliseconds(16))
            if steps.count > 200 { break }
        }
        frames.stop()
        let afterScroll = PerfHostedReport.footprintMegabytes()
        let worst = steps.max() ?? .zero
        PerfHostedReport.line("scroll 230 results | \(steps.count) screenfuls | worst \(PerfHostedReport.text(worst)), mean \(PerfHostedReport.text(steps.reduce(.zero, +) / max(1, steps.count))) | longest frame \(PerfHostedReport.text(frames.longest))")
        PerfHostedReport.line("memory footprint | before \(before) MB | 10 000 items on Home \(afterLaunch) MB | after search and scroll \(afterScroll) MB | process peak \(PerfHostedReport.peakResidentMegabytes()) MB")
        #expect(steps.count > 3)
        #expect(worst < Self.stallLimit)
        // The whole inventory is never held in memory: a 10 000-row load would show here.
        #expect(afterScroll - before < 400)
    }
}

/// The query classes measured on the simulator (the package's PerfQuery, docs/PERFORMANCE.md).
enum PerfHostedQuery: String, CaseIterable {
    case oneLetter = "a"
    case twoLetters = "sc"
    case commonWord = "screws"
    case containerType = "box"
    case spaceName = "garage"
    case accented = "crème"
    case rareTwoWords = "jumper cables"
    case nothing = "zzqx"
    case shortCode = "BOX-7K"
    case threeWords = "red screws 4x40"

    var label: String {
        switch self {
        case .oneLetter: "1 letter"
        case .twoLetters: "2 letters"
        case .commonWord: "common word"
        case .containerType: "container type"
        case .spaceName: "space name"
        case .accented: "accented"
        case .rareTwoWords: "rare, 2 words"
        case .nothing: "no match"
        case .shortCode: "short code"
        case .threeWords: "3 words"
        }
    }
}

/// The large demo container booted in a window of its own.
@MainActor
final class PerfHostedHarness {
    let app: AppContainer
    let host: ShellTestWindow

    private init(app: AppContainer, host: ShellTestWindow) {
        self.app = app
        self.host = host
    }

    static func start() async throws -> PerfHostedHarness {
        let started = ContinuousClock.now
        let app = ShellDemoLargeSeed.container(
            platform: .silent(), onboardingCompleted: true, householdSession: nil, transport: ShellOfflineTransport())
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        let harness = PerfHostedHarness(app: app, host: host)
        await ShellTestWait.until("the main shell", timeout: .seconds(60)) { app.boot.phase == .main && app.router.acceptsNavigation }
        await ShellTestWait.until("Home's recent rows", timeout: .seconds(60)) {
            app.home.recentRows?.isEmpty == false && app.home.spaces.data != nil
        }
        host.window.layoutIfNeeded()
        let build = ShellDemoLargeSeed.lastBuild.withLock { $0 }
        PerfHostedReport.line("launch with 10 000 items (seed written at boot) → Home drawn | \(PerfHostedReport.text(ContinuousClock.now - started)) | of which photos \(PerfHostedReport.text(build?.photos ?? .zero)), rows \(PerfHostedReport.text(build?.rows ?? .zero))")
        return harness
    }

    func close() {
        host.close()
    }

    /// Types `query` as one keystroke and returns the time until its results are on screen.
    func typeAndWaitForResults(_ query: String) async throws -> Duration {
        let started = ContinuousClock.now
        app.home.setQuery(query)
        await waitForResults(of: query)
        return ContinuousClock.now - started
    }

    /// Waits until the search for `query` has settled and Home's list has drawn it.
    func waitForResults(of query: String) async {
        let home = app.home
        await Self.until("results for \(query)") {
            home.search.settledQuery == query.trimmingCharacters(in: .whitespaces) && !home.search.pending && !home.search.refreshing
        }
        // The next layout pass draws the new rows (SwiftUI applies them in it).
        host.window.layoutIfNeeded()
        await ShellTestWait.until("the list drawn for \(query)", timeout: .seconds(30)) {
            (self.homeList()?.perfItemCount ?? 0) > 0
        }
    }

    /// Polls every millisecond (`ShellTestWait.until` sleeps 20 ms between looks, too coarse
    /// to time with).
    static func until(_ description: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Home's list: the collection view under the Home tab.
    func homeList() -> UICollectionView? {
        host.window.shellDescendants.compactMap { $0 as? UICollectionView }
            .filter { $0.window != nil && !$0.isHidden }
            .max { $0.perfItemCount < $1.perfItemCount }
    }

    /// Waits until some list on screen (a pushed screen, a sheet) holds at least `rows` rows.
    func waitForList(rows: Int, description: String) async {
        await ShellTestWait.until(description, timeout: .seconds(30)) {
            self.allViews().contains { view in
                guard let list = view as? UICollectionView, list.window != nil else { return false }
                return list.perfItemCount >= rows && list.visibleCells.count > 3
            }
        }
    }

    private func allViews() -> [UIView] {
        var views = host.window.shellDescendants
        var presented = host.window.rootViewController?.presentedViewController
        while let controller = presented {
            views += [controller.view] + controller.view.shellDescendants
            presented = controller.presentedViewController
        }
        return views
    }
}

extension UICollectionView {
    /// Rows in every section.
    var perfItemCount: Int {
        (0..<numberOfSections).reduce(0) { $0 + numberOfItems(inSection: $1) }
    }
}

/// Watches the main thread's frames: the gap between one display refresh and the next.
@MainActor
final class PerfFrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var gaps: [Duration] = []

    var frames: Int { gaps.count }
    var longest: Duration { gaps.max() ?? .zero }

    func count(over limit: Duration) -> Int {
        gaps.filter { $0 > limit }.count
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last {
            gaps.append(.milliseconds(Int64(((link.timestamp - last) * 1000).rounded())))
        }
        last = link.timestamp
    }
}

enum PerfHostedReport {
    static func line(_ text: String) {
        print("PERF | \(text)")
    }

    static func text(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0f ms", milliseconds)
    }

    /// "s", "sc", … "screwdriver".
    static func prefixes(of word: String) -> [String] {
        (1...word.count).map { String(word.prefix($0)) }
    }

    /// The process's memory footprint now, in megabytes (`phys_footprint`, what Xcode's memory
    /// gauge and the jetsam limit count).
    static func footprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        // `task_self_trap()` rather than the `mach_task_self_` global, which Swift 6 refuses.
        let task = task_self_trap()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// The process's peak resident memory so far, in megabytes (`getrusage`).
    static func peakResidentMegabytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        // Bytes on Darwin.
        return Int(usage.ru_maxrss / 1_048_576)
    }
}

import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The account screens' wiring to the app: each builds its model when it appears (an empty view
/// never gets `onAppear`, which left a screen blank), the Household screen follows the session
/// live and reads the phone list, and its exit only closes the screen while it is in front
/// (04 §12.1).
@Suite("Account screens (hosted)", .serialized)
@MainActor
struct AccountScreenWiringTests {
    private func booted(_ scenario: AccountDemoScenario) async -> (AppContainer, AccountDemoServer) {
        let (app, server) = AppContainer.accountDemoWithServer(scenario, platform: .silent())
        await app.boot.run()
        return (app, server)
    }

    /// A window in front of the others: a list lays its rows out only in a window on screen, and
    /// an earlier test's window may still be on top.
    private func host(_ content: some View) throws -> ShellTestWindow {
        let host = try ShellTestWindow(content)
        host.window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        host.window.makeKeyAndVisible()
        return host
    }

    /// The rows a `Form` or `List` has drawn: none for a screen that stayed blank. (SwiftUI draws
    /// its text fields itself, so they cannot be counted.)
    private func listRows(in window: UIWindow) -> Int {
        window.shellDescendants.filter { $0 is UICollectionViewCell }.count
    }

    @Test("the paired Household screen reads the phone list as soon as it shows")
    func pairedReadsPhones() async throws {
        let (app, server) = await booted(.paired)
        let window = try host(NavigationStack { HouseholdScreen() }.shellEnvironment(app))
        defer { window.close() }

        await ShellTestWait.until("the phone list read") { server.requests.contains("GET /v1/devices") }
        // Its rows are drawn (a blank screen has none).
        await ShellTestWait.until("the paired rows") { listRows(in: window.window) >= 1 }
    }

    @Test("joining swaps the join form for the paired view, which then reads the phone list")
    func joinSwapsToPaired() async throws {
        let (app, server) = await booted(.unpaired)
        let window = try host(NavigationStack { HouseholdScreen() }.shellEnvironment(app))
        defer { window.close() }

        // The join form is drawn.
        await ShellTestWait.until("the join form's rows") { listRows(in: window.window) >= 1 }
        #expect(!server.requests.contains("GET /v1/devices"))

        try await app.household.pair(bootstrapSecret: AccountDemoServer.householdCode, deviceName: "Anna’s iPhone")

        await ShellTestWait.until("the phone list read") { server.requests.contains("GET /v1/devices") }
    }

    @Test("Backup off draws its two parts from the first appearance")
    func backupOffDraws() async throws {
        let (app, _) = await booted(.backupOff)
        let window = try host(NavigationStack { BackupScreen() }.shellEnvironment(app))
        defer { window.close() }

        // The form is drawn (a blank screen has no rows).
        await ShellTestWait.until("the form's rows") { listRows(in: window.window) >= 1 }
    }

    @Test("onboarding's Join step builds and shows the join form")
    func onboardingJoinStep() async throws {
        let (app, _) = await booted(.onboarding)
        let window = try host(
            OnboardingScreen()
                .environment(\.accountDemoOnboardingStart, .join)
                .shellEnvironment(app)
        )
        defer { window.close() }

        await ShellTestWait.until("the join form's rows") { listRows(in: window.window) >= 1 }
    }

    @Test("onboarding's Join step keeps to RN's 480 pt column in a wide window (iPad)")
    func onboardingJoinColumn() async throws {
        let (app, _) = await booted(.onboarding)
        let window = try host(
            OnboardingScreen()
                .environment(\.accountDemoOnboardingStart, .join)
                .shellEnvironment(app)
        )
        defer { window.close() }
        window.window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)

        await ShellTestWait.until("the join form's rows") { listRows(in: window.window) >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        let form = try #require(window.window.shellDescendants.compactMap { $0 as? UICollectionView }.max { $0.bounds.width < $1.bounds.width })
        #expect(form.bounds.width <= 480)
        #expect(form.bounds.width > 300)
    }

    @Test("each Backup state that replaces the page names the part VoiceOver moves to")
    func backupFocusParts() {
        #expect(BackupFocusPart(.off) == .keep)
        #expect(BackupFocusPart(.revealed(BackupRevealedCode(code: "89144GJ289144GJ28914GJ288"))) == .writeDown)
        #expect(BackupFocusPart(.on) == .on)
        #expect(BackupFocusPart(.unavailable) == nil)
        #expect(BackupFocusPart(.unreadable) == nil)
    }

    @Test("leaving Household closes it only while it is in front")
    func exitOnlyWhenFocused() async {
        let (app, _) = await booted(.paired)
        let router = app.router
        let household = router.push(.household)
        HouseholdScreenExit.leave(router: router, address: household.address)
        #expect(router.path(router.selectedTab).isEmpty)

        let again = router.push(.household)
        _ = router.push(.privacy)
        HouseholdScreenExit.leave(router: router, address: again.address)
        #expect(router.path(router.selectedTab).map(\.route) == [.household, .privacy])

        // Outside the shell (previews) there is no address: nothing happens.
        HouseholdScreenExit.leave(router: router, address: nil)
        #expect(router.path(router.selectedTab).count == 2)
    }
}

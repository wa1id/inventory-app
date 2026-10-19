import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN `useRepositories()` (src/providers/DatabaseProvider.tsx:108-120; 09 §4.1) and Home's
// unpaired notice (src/ui/home/unpairedNotice.ts; 04 §12.8), which has no RN tests.

@MainActor
private final class LocalSlot {
    var repositories: LocalRepositories?
}

@MainActor
@Suite("RepositoryProvider")
struct HouseholdRepositoryProviderTests {
    @Test("nothing before the database is ready; local while unpaired; shadowed household while paired")
    func composition() async throws {
        let household = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: householdModelSession.jsonString])) { request in
            request.method == "POST"
                ? .json(201, ##"{"id":"server-space","name":"Garage","icon":"🚗","color":"#5B8DEF","createdAt":1,"updatedAt":1}"##)
                : .json(200, #"{"spaces":[]}"#)
        }
        let slot = LocalSlot()
        let provider = RepositoryProvider(household: household.household, localRepositories: { slot.repositories })
        #expect(provider.repositories == nil)
        #expect(provider.localRepositories == nil)

        let local = try householdModelLocal()
        slot.repositories = local
        #expect(provider.repositories is LocalRepositories)
        #expect(!provider.isPaired)

        await household.household.load()
        #expect(provider.isPaired)
        let paired = try #require(provider.repositories as? ShadowingRepositories)
        #expect(paired.remote.session == householdModelSession)
        // The raw local repositories stay reachable, never shadowed (join snapshot, import).
        #expect(provider.localRepositories?.store === local.store)

        // A write goes to the home server and lands in the local database too.
        let repos = try #require(provider.repositories)
        _ = try await repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "🚗", color: "#5B8DEF"))
        #expect(household.server.lastRequest?.line == "POST https://inventory.wystudio.be/v1/spaces")
        #expect(try await local.spaces.getById("server-space")?.name == "Garage")

        household.household.disconnect(revokeDevice: false)
        #expect(provider.repositories is LocalRepositories)
    }
}

@MainActor
@Suite("UnpairedNoticeModel")
struct HouseholdUnpairedNoticeModelTests {
    @Test("hidden until the preference is read, so it never flashes")
    func hiddenUntilRead() {
        let notice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences()))
        #expect(notice.dismissed == nil)
        #expect(!notice.isVisible(paired: false))
        notice.load()
        #expect(notice.dismissed == false)
        #expect(notice.isVisible(paired: false))
    }

    @Test("never shown on a paired phone")
    func pairedPhone() {
        let notice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences()))
        notice.load()
        #expect(!notice.isVisible(paired: true))
    }

    @Test("a dismissal stored as exactly \"1\" keeps it away", arguments: [("1", false), ("true", true), ("", true)])
    func storedValue(stored: String, visible: Bool) {
        let notice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences([PreferenceKey.unpairedNoticeDismissed: stored])))
        notice.load()
        #expect(notice.isVisible(paired: false) == visible)
    }

    @Test("Not now hides it at once and remembers \"1\"; a later read never brings it back")
    func dismiss() {
        let preferences = InMemoryPreferences()
        let notice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: preferences))
        notice.dismiss()
        #expect(!notice.isVisible(paired: false))
        #expect(preferences.values[PreferenceKey.unpairedNoticeDismissed] == "1")
        preferences.removeValue(forKey: PreferenceKey.unpairedNoticeDismissed)
        notice.load()
        #expect(notice.dismissed == true)

        let next = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: InMemoryPreferences([PreferenceKey.unpairedNoticeDismissed: "1"])))
        next.load()
        #expect(!next.isVisible(paired: false))
    }
}

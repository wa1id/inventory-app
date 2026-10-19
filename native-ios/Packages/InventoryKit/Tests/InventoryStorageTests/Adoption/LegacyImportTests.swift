import Foundation
import Testing
@testable import InventoryStorage

/// 02 §11.2 #2, against the committed RN store fixture and a throwaway `UserDefaults` suite.
@Suite("LegacyImport")
@MainActor
struct LegacyImportTests {
    static let storePath = LegacyAsyncStorageReaderTests.storePath

    func makeImport(
        _ container: TemporaryContainer, _ defaults: TemporaryDefaults, protectedData: Bool = true
    ) -> LegacyImport {
        LegacyImport(
            defaults: defaults.defaults, reader: LegacyAsyncStorageReaderTests.reader(container),
            isProtectedDataAvailable: { protectedData })
    }

    @Test("imports the seven keys verbatim, including the overflow value")
    func importsSevenKeys() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        let expected = try LegacyAsyncStorageReaderTests.expectedFixtureValues()

        let outcome = makeImport(container, suite).runIfNeeded()

        #expect(outcome == .imported(keys: PreferenceKey.legacyKeys))
        for key in PreferenceKey.legacyKeys {
            #expect(suite.defaults.object(forKey: key) as? String == expected[key], "\(key)")
        }
        #expect(suite.defaults.object(forKey: LegacyImport.markerKey) as? Int == 1)
    }

    @Test("the imported strings read back through the preference stores with RN's rules")
    func readersAfterImport() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        makeImport(container, suite).runIfNeeded()

        let preferences = suite.defaults
        #expect(OnboardingPreference(preferences: preferences).isCompleted)
        #expect(UnpairedNoticePreference(preferences: preferences).isDismissed)
        #expect(LastBackupPreference(preferences: preferences).lastBackupAt == 1_754_236_800_000)
        #expect(RecentPlacesStore(preferences: preferences).read()
            == ["3f1c2a9e-8b7d-4c1e-9f00-1a2b3c4d5e6f", "0b6d8a52-1c3e-4f7a-9b2d-5e8f1a3c7d90"])
        let join = HouseholdJoinPreferences(preferences: preferences)
        #expect(join.hasJoinedBefore)
        #expect(join.importOffer == ImportOffer(spaces: 3, items: 41))
        let categories = CategoryMemory(preferences: preferences).known
        #expect(categories.count == 20)
        #expect(categories.first == "Garden tools & watering cans for the allotment")
        #expect(categories.contains("DIY/Tools — drills, drivers, bits and spare batteries"))
    }

    @Test("ignores keys that are not one of the seven")
    func ignoresUnknownKeys() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        makeImport(container, suite).runIfNeeded()
        #expect(suite.defaults.object(forKey: "debug.lastOpenedUrl") == nil)
        #expect(suite.defaults.object(forKey: "some.removed.value") == nil)
    }

    @Test("never overwrites a value native already has")
    func neverOverwrites() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        suite.defaults.set("[\"native\"]", forKey: PreferenceKey.recentPlaces)
        suite.defaults.set(42, forKey: PreferenceKey.lastBackupAt)

        let outcome = makeImport(container, suite).runIfNeeded()

        #expect(suite.defaults.object(forKey: PreferenceKey.recentPlaces) as? String == "[\"native\"]")
        #expect(suite.defaults.object(forKey: PreferenceKey.lastBackupAt) as? Int == 42)
        #expect(outcome == .imported(keys: PreferenceKey.legacyKeys.filter {
            $0 != PreferenceKey.recentPlaces && $0 != PreferenceKey.lastBackupAt
        }))
    }

    @Test("leaves the marker unset when the manifest cannot be read, and retries next launch")
    func unreadableManifestRetries() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try container.write(Data([0x7B, 0xFF, 0x7D]), to: Self.storePath + "/manifest.json")

        #expect(makeImport(container, suite).runIfNeeded() == .failed(.manifestNotUTF8))
        #expect(suite.defaults.object(forKey: LegacyImport.markerKey) == nil)
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil)

        // Next launch, the store is readable again.
        try FileManager.default.removeItem(at: container.root.appending(path: Self.storePath))
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        #expect(makeImport(container, suite).runIfNeeded() == .imported(keys: PreferenceKey.legacyKeys))
    }

    @Test("leaves the marker unset when an overflow file exists but is unreadable")
    func unreadableOverflow() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        try container.write(Data([0xC3, 0x28]), to: Self.storePath + "/9355fb19fd0f6f39f84680882e0638d7")

        #expect(makeImport(container, suite).runIfNeeded() == .failed(.unreadableValue(key: "categories.recent.v1")))
        #expect(suite.defaults.object(forKey: LegacyImport.markerKey) == nil)
        // Nothing is half-imported.
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil)
    }

    @Test("an unreadable overflow file of a key that is not one of the seven does not block the import")
    func unrelatedUnreadableOverflow() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try container.write(
            Data(#"{"onboarding.completed.v1":"true","some.other.library.key":null}"#.utf8),
            to: Self.storePath + "/manifest.json")
        try container.write(
            Data([0xC3, 0x28]), to: Self.storePath + "/" + LegacyAsyncStorageReader.md5Hex("some.other.library.key"))

        #expect(makeImport(container, suite).runIfNeeded() == .imported(keys: [PreferenceKey.onboardingCompleted]))
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) as? String == "true")
        #expect(suite.defaults.integer(forKey: LegacyImport.markerKey) == 1)
    }

    @Test("reads nothing and leaves the marker unset while protected data is unavailable")
    func protectedDataUnavailable() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        // Reading this manifest would fail; the outcome shows it was never read.
        try container.write(Data([0xFF]), to: Self.storePath + "/manifest.json")

        #expect(makeImport(container, suite, protectedData: false).runIfNeeded() == .protectedDataUnavailable)
        #expect(suite.defaults.object(forKey: LegacyImport.markerKey) == nil)
    }

    @Test("is a no-op once the marker is set")
    func noOpOnceMarked() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        suite.defaults.set(1, forKey: LegacyImport.markerKey)
        suite.defaults.set(7, forKey: "ExpoSystemUI.backgroundColor")

        #expect(makeImport(container, suite).runIfNeeded() == .alreadyImported)
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil)
        #expect(suite.defaults.object(forKey: "ExpoSystemUI.backgroundColor") as? Int == 7)

        // A second run after a real import is also a no-op.
        let fresh = try TemporaryDefaults()
        #expect(makeImport(container, fresh).runIfNeeded() == .imported(keys: PreferenceKey.legacyKeys))
        fresh.defaults.removeObject(forKey: PreferenceKey.onboardingCompleted)
        #expect(makeImport(container, fresh).runIfNeeded() == .alreadyImported)
        #expect(fresh.defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil)
    }

    @Test("removes ExpoSystemUI.backgroundColor")
    func removesExpoSystemUIKey() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        suite.defaults.set(15_658_734, forKey: "ExpoSystemUI.backgroundColor")
        #expect(makeImport(container, suite).runIfNeeded() == .imported(keys: []))
        #expect(suite.defaults.object(forKey: "ExpoSystemUI.backgroundColor") == nil)
    }

    @Test("a fresh install (no RN store) imports nothing and sets the marker")
    func freshInstall() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        #expect(makeImport(container, suite).runIfNeeded() == .imported(keys: []))
        #expect(suite.defaults.integer(forKey: LegacyImport.markerKey) == 1)
    }

    @Test("leaves the RN directory untouched")
    func leavesRNDirectory() throws {
        let container = try TemporaryContainer()
        let suite = try TemporaryDefaults()
        try LegacyAsyncStorageReaderTests.installFixture(in: container)
        let manifest = container.root.appending(path: Self.storePath + "/manifest.json")
        let before = try Data(contentsOf: manifest)
        makeImport(container, suite).runIfNeeded()
        #expect(try Data(contentsOf: manifest) == before)
        #expect(container.exists(Self.storePath + "/9355fb19fd0f6f39f84680882e0638d7"))
    }
}

import Foundation
import Testing
@testable import InventoryStrings

/// Every strings.ts entry, static or function, against the output of the real
/// TypeScript (Fixtures/strings-parity.json).
@Suite("strings.ts parity")
struct StringsParityTests {
    static let fixture = StringsFixture.shared

    static func expectParity(_ entry: StringsFixture.Entry) throws {
        for testCase in entry.cases {
            let actual = try callStringsAccessor(entry.path, testCase.args)
            #expect(actual == testCase.expected, "\(entry.path)(\(testCase.args.map(\.description).joined(separator: ", ")))")
        }
    }

    /// Runs every accessor (and `Format.ago`) against `bundle` with the English
    /// fallback switched off, and returns the catalog keys they read.
    static func expectStrictParity(_ bundle: Bundle) throws -> Set<String> {
        let log = L10nRuntime.KeyLog()
        try L10nRuntime.$override.withValue(.init(bundle: bundle, strict: true, log: log)) {
            for entry in fixture.entries {
                try expectParity(entry)
            }
            for vector in fixture.format.ago {
                #expect(Format.ago(vector.ms, now: vector.now) == vector.expected, "ago(\(vector.ms), now: \(vector.now))")
            }
        }
        return log.keys
    }

    /// Every catalog key is reachable from an accessor, and every key an accessor reads exists.
    static func expectKeyCoverage(_ resolved: Set<String>) {
        let expected = Set(fixture.catalogKeys)
        #expect(expected.subtracting(resolved).sorted() == [], "catalog keys no accessor reads")
        #expect(resolved.subtracting(expected).sorted() == [], "keys accessors read that the catalog lacks")
    }

    /// First the default path, as the app calls it: `Bundle.module` with the English
    /// fallback (under `swift test` the catalog is only copied, so this is the
    /// fallback; in an Xcode build it is the compiled catalog). Then the fallback on
    /// its own, against a bundle with no catalog, so it is checked in either build.
    @Test("every accessor reproduces strings.ts", arguments: StringsFixture.shared.entries.map(\.path))
    func accessorMatchesStringsTs(path: String) throws {
        let entry = try #require(Self.fixture.entries.first { $0.path == path })
        try Self.expectParity(entry)
        try #require(NoCatalog.holdsNoCatalog, "the test bundle must not hold a Localizable table")
        try L10nRuntime.$override.withValue(.init(bundle: NoCatalog.bundle, strict: false, log: nil)) {
            try Self.expectParity(entry)
        }
    }

    /// The app's own lookup with the fallback switched off: `Bundle.module` as Xcode
    /// builds it, in the app or in the package tests run by xcodebuild on a simulator
    /// (see scripts/strings/README.md). `swift test` only copies the catalog, so it
    /// skips this; the xcstringstool test below covers the same files there.
    @Test(
        "the module's compiled catalog reproduces strings.ts through every accessor",
        .enabled(if: L10nRuntime.bundle.url(forResource: "Localizable", withExtension: "strings") != nil,
                 "Bundle.module holds a compiled catalog only in Xcode builds")
    )
    func moduleCatalogMatchesStringsTs() throws {
        Self.expectKeyCoverage(try Self.expectStrictParity(L10nRuntime.bundle))
    }

    #if os(macOS)
    /// The app path: the catalog compiled by xcstringstool (the same files Xcode puts
    /// in the app), resolved through Foundation, with no English fallback.
    @Test("the compiled catalog reproduces strings.ts through every accessor")
    func compiledCatalogMatchesStringsTs() throws {
        let compiled = try CompiledCatalog.result.get()
        Self.expectKeyCoverage(try Self.expectStrictParity(compiled.bundle))
    }

    @Test("xcstringstool compiles the catalog without warnings")
    func catalogCompilesCleanly() throws {
        let compiled = try CompiledCatalog.result.get()
        #expect(compiled.log.trimmingCharacters(in: .whitespacesAndNewlines) == "")
    }

    @Test("the compiled catalog holds every key and no extras")
    func compiledCatalogKeys() throws {
        let compiled = try CompiledCatalog.result.get()
        let folder = compiled.directory.appendingPathComponent("en.lproj")
        let strings = NSDictionary(contentsOf: folder.appendingPathComponent("Localizable.strings")) as? [String: Any] ?? [:]
        let plurals = NSDictionary(contentsOf: folder.appendingPathComponent("Localizable.stringsdict")) as? [String: Any] ?? [:]
        let keys = Set(strings.keys).union(plurals.keys)
        #expect(keys == Set(Self.fixture.catalogKeys))
    }

    /// Spec 08 §11 (a).
    @Test("every compiled key resolves to a non-empty value that is not its key")
    func compiledValuesAreReal() throws {
        let compiled = try CompiledCatalog.result.get()
        for key in Self.fixture.catalogKeys {
            let value = compiled.bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
            #expect(value != "\u{0}missing" && !value.isEmpty && value != key, "\(key)")
        }
    }
    #endif

    @Test("the source catalog holds every key and no extras")
    func sourceCatalogKeys() throws {
        let data = try Data(contentsOf: CatalogSource.url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        #expect(Set(strings.keys) == Set(Self.fixture.catalogKeys))
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any]
            #expect(localizations?["en"] != nil, "\(key) has an English value")
            #expect(entry["extractionState"] as? String == "manual", "\(key) is managed by the generator")
        }
    }

    @Test("every strings.ts path has a parity entry")
    func fixtureCoversEveryAccessor() throws {
        // The dispatch is generated from the same tree; an unknown path would throw here.
        for entry in Self.fixture.entries {
            #expect(!entry.cases.isEmpty, "\(entry.path)")
            _ = try callStringsAccessor(entry.path, entry.cases[0].args)
        }
        #expect(Self.fixture.entries.count == Set(Self.fixture.entries.map(\.path)).count)
    }
}

/// Spec 08 §11 (c), (d) and the lookup-map semantics.
@Suite("L10n")
struct L10nTests {
    @Test("emoji keys keep their exact code points")
    func emojiKeysRoundTrip() {
        let sofa = L10n.Entities.IconNames.allKeys[0]
        #expect(sofa.unicodeScalars.map(\.value) == [0x1F6CB, 0xFE0F])
        #expect(L10n.Entities.IconNames["\u{1F6CB}\u{FE0F}"] == "Sofa")
        #expect(L10n.Entities.IconNames["\u{1F6CB}"] == nil)
        #expect(L10n.Entities.IconNames[" \u{1F697}"] == nil)
    }

    @Test("where.notFiledYet keeps its two no-break spaces")
    func notFiledYetKeepsNoBreakSpaces() {
        #expect(L10n.Where.notFiledYet.unicodeScalars.filter { $0 == "\u{00A0}" }.count == 2)
        #expect(L10n.Where.notFiledYet == "\u{00A0}·\u{00A0}not filed yet")
    }

    @Test("lookup maps match keys exactly, as JS objects do")
    func mapsAreExact() {
        #expect(L10n.Entities.TypeNames["box"] == "Box")
        #expect(L10n.Entities.TypeNames["Box"] == nil)
        #expect(L10n.Entities.ColourNames["#5B8DEF"] == "Blue")
        #expect(L10n.Entities.ColourNames["#5b8def"] == nil)
        #expect(L10n.Suggestions.FailedBody["rate_limited"] == L10n.Suggestions.FailedBody.rate_limited)
        // é precomposed and decomposed are equal to Swift's ==, not to JS ===.
        #expect(L10nRuntime.same("\u{00E9}", "e\u{0301}") == false)
    }

    @Test("counts are never grouped, whatever the locale")
    func countsAreNotGrouped() {
        #expect(L10n.Rows.times(count: 1234) == "×1234")
        #expect(L10n.Entities.items(count: 1_000_000) == "1000000 items")
        #expect(L10n.Home.summary(spaces: 1, containers: 1234, items: 0) == "1 space, 1234 containers and 0 items.")
    }
}

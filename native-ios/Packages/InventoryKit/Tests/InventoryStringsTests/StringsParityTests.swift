import Foundation
import Testing
@testable import InventoryStrings

/// Every strings.ts entry, static or function, against the output of the real
/// TypeScript (Fixtures/strings-parity.json).
@Suite("strings.ts parity")
struct StringsParityTests {
    static let fixture = StringsFixture.shared

    /// Under `swift test` the catalog is not compiled, so this checks the English
    /// fallback path, including the plural variants resolved in L10nRuntime.
    @Test("every accessor reproduces strings.ts", arguments: StringsFixture.shared.entries.map(\.path))
    func accessorMatchesStringsTs(path: String) throws {
        let entry = try #require(Self.fixture.entries.first { $0.path == path })
        for testCase in entry.cases {
            let actual = try callStringsAccessor(path, testCase.args)
            #expect(actual == testCase.expected, "\(path)(\(testCase.args.map(\.description).joined(separator: ", ")))")
        }
    }

    #if os(macOS)
    /// The app path: the catalog compiled by xcstringstool, resolved through Foundation,
    /// with no English fallback. Also proves every catalog key is reachable from an
    /// accessor and every accessor's key exists.
    @Test("the compiled catalog reproduces strings.ts through every accessor")
    func compiledCatalogMatchesStringsTs() throws {
        let compiled = try CompiledCatalog.result.get()
        let log = L10nRuntime.KeyLog()
        try L10nRuntime.$override.withValue(.init(bundle: compiled.bundle, strict: true, log: log)) {
            for entry in Self.fixture.entries {
                for testCase in entry.cases {
                    let actual = try callStringsAccessor(entry.path, testCase.args)
                    #expect(actual == testCase.expected, "\(entry.path)(\(testCase.args.map(\.description).joined(separator: ", ")))")
                }
            }
            for vector in Self.fixture.format.ago {
                #expect(Format.ago(vector.ms, now: vector.now) == vector.expected, "ago(\(vector.ms), now: \(vector.now))")
            }
        }
        let resolved = log.keys
        let expected = Set(Self.fixture.catalogKeys)
        #expect(expected.subtracting(resolved).sorted() == [], "catalog keys no accessor reads")
        #expect(resolved.subtracting(expected).sorted() == [], "keys accessors read that the catalog lacks")
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

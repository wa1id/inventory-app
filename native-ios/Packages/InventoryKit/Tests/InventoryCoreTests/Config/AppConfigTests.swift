import Foundation
import Testing
@testable import InventoryCore

// 09 §14.2 AppConfigTests: each §8.1 rule (RN has no config tests), plus
// Fixtures/config.json (src/services/config.ts run with each value) and a check
// of the committed Info.plist and xcconfigs.

private func config(_ values: [AppConfig.InfoKey: Any], version: Any? = nil) -> AppConfig {
    var info: [String: Any] = [:]
    for (key, value) in values {
        info[key.rawValue] = value
    }
    if let version {
        info["CFBundleShortVersionString"] = version
    }
    return AppConfig(infoDictionary: info)
}

/// Every text setting set to the same value.
private func allText(_ value: String) -> AppConfig {
    config([.recognitionURL: value, .recognitionKey: value, .syncURL: value, .syncKey: value, .householdOrigin: value])
}

@Suite("AppConfig")
struct AppConfigTests {
    @Test("every setting has its default when the Info.plist has none")
    func defaultsWhenUnset() {
        let parsed = AppConfig(infoDictionary: [:])
        #expect(parsed == AppConfig())
        #expect(parsed.recognitionEndpoint == nil)
        #expect(parsed.recognitionKey == nil)
        #expect(parsed.recognitionTimeoutMs == 15_000)
        #expect(parsed.syncEndpoint == nil)
        #expect(parsed.syncKey == nil)
        #expect(parsed.syncTimeoutMs == 60_000)
        #expect(parsed.householdOrigin == "https://inventory.wystudio.be")
        #expect(parsed.environment == .development)
        #expect(parsed.appVersion == "0.0.0")
    }

    @Test("an unset xcconfig variable, which expands to an empty string, counts as absent")
    func emptyMeansAbsent() {
        var info: [String: Any] = [:]
        for key in AppConfig.InfoKey.allCases {
            info[key.rawValue] = ""
        }
        info["CFBundleShortVersionString"] = ""
        #expect(AppConfig(infoDictionary: info) == AppConfig())
    }

    @Test("reads every key")
    func readsEveryKey() {
        let parsed = config([
            .environment: "production",
            .recognitionURL: "https://server-wy-studio.vercel.app/api/recognize",
            .recognitionKey: "rk",
            .recognitionTimeoutMs: "16000",
            .syncURL: "https://inventory-sync.wyachou95.workers.dev",
            .syncKey: "sk",
            .syncTimeoutMs: "61000",
            .householdOrigin: "https://home.example",
        ], version: "0.2.0")
        #expect(parsed == AppConfig(
            recognitionEndpoint: "https://server-wy-studio.vercel.app/api/recognize",
            recognitionKey: "rk",
            recognitionTimeoutMs: 16_000,
            syncEndpoint: "https://inventory-sync.wyachou95.workers.dev",
            syncKey: "sk",
            syncTimeoutMs: 61_000,
            householdOrigin: "https://home.example",
            environment: .production,
            appVersion: "0.2.0"
        ))
    }

    @Test("trims every text setting with JS trim(); empty after trimming means absent")
    func trimsWithJSRules() {
        let padded = allText(" \t https://a.example\n")
        #expect(padded.recognitionEndpoint == "https://a.example")
        #expect(padded.recognitionKey == "https://a.example")
        #expect(padded.syncEndpoint == "https://a.example")
        #expect(padded.syncKey == "https://a.example")
        #expect(padded.householdOrigin == "https://a.example")

        // JS trims U+FEFF and U+3000 but not U+0085 or U+200B.
        #expect(allText("\u{FEFF}key\u{3000}").recognitionKey == "key")
        #expect(allText("\u{85}key").recognitionKey == "\u{85}key")
        #expect(allText("\u{200B}key").syncKey == "\u{200B}key")

        let blank = allText(" \n\t\u{A0} ")
        #expect(blank.recognitionEndpoint == nil)
        #expect(blank.recognitionKey == nil)
        #expect(blank.syncEndpoint == nil)
        #expect(blank.syncKey == nil)
        #expect(blank.householdOrigin == AppConfig.defaultHouseholdOrigin)
    }

    @Test("strips trailing slashes from the sync URL and the household origin, not from the recognition URL")
    func stripsTrailingSlashes() {
        let parsed = allText("https://a.example/path///")
        #expect(parsed.syncEndpoint == "https://a.example/path")
        #expect(parsed.householdOrigin == "https://a.example/path")
        #expect(parsed.recognitionEndpoint == "https://a.example/path///")
        #expect(parsed.recognitionKey == "https://a.example/path///")
        #expect(parsed.syncKey == "https://a.example/path///")
        #expect(allText(" https://a.example/ ").syncEndpoint == "https://a.example")
    }

    @Test("only slashes leave the sync URL unset and the household origin at its default")
    func onlySlashes() {
        for value in ["/", "///", " / "] {
            #expect(allText(value).syncEndpoint == nil)
            #expect(allText(value).householdOrigin == AppConfig.defaultHouseholdOrigin)
            #expect(allText(value).recognitionEndpoint == value.jsTrimmed())
        }
    }

    @Test("keeps white space that sits before the trailing slashes, as JS does")
    func keepsSpaceBeforeSlashes() {
        #expect(allText("https://a.example /").syncEndpoint == "https://a.example ")
        #expect(allText("/ /").householdOrigin == "/ ")
    }

    @Test("the environment is production or preview exactly, otherwise development", arguments: [
        ("production", AppConfig.Environment.production),
        ("preview", .preview),
        ("development", .development),
        ("", .development),
        ("Production", .development),
        ("PREVIEW", .development),
        (" production", .development),
        ("production ", .development),
        ("preview\n", .development),
        ("staging", .development),
    ])
    func environment(raw: String, expected: AppConfig.Environment) {
        #expect(config([.environment: raw]).environment == expected)
    }

    @Test("timeouts parse with JS Number()", arguments: [
        ("20000", 20_000), (" 20000 ", 20_000), ("\u{A0}30000\u{FEFF}", 30_000), ("1.5e4", 15_000),
        (".5e4", 5_000), ("0x3A98", 15_000), ("0b101", 5), ("+500", 500), ("5.", 5), ("1", 1),
    ])
    func timeoutsParseWithJSNumber(raw: String, expected: Int) {
        let parsed = config([.recognitionTimeoutMs: raw, .syncTimeoutMs: raw])
        #expect(parsed.recognitionTimeoutMs == expected)
        #expect(parsed.syncTimeoutMs == expected)
    }

    @Test("a fractional timeout is truncated to whole milliseconds")
    func fractionalTimeoutsTruncate() {
        #expect(config([.syncTimeoutMs: "20000.7"]).syncTimeoutMs == 20_000)
        #expect(config([.syncTimeoutMs: "1.9"]).syncTimeoutMs == 1)
    }

    // 00-index §5 / 09 §15 Q14: RN keeps 0 or NaN, which aborts every request at once.
    @Test("empty, non-numeric and non-positive timeouts fall back to the defaults", arguments: [
        "", " ", "abc", "12abc", "0", "-0", "-1", "-20000", "0.4", "0.9999", "Infinity", "-Infinity",
        "infinity", "NaN", "1e400", "1_000", "1,000", "\u{663}\u{660}\u{660}", "\u{FF11}\u{FF15}", "0x", "1e",
    ])
    func unusableTimeoutsFallBack(raw: String) {
        let parsed = config([.recognitionTimeoutMs: raw, .syncTimeoutMs: raw])
        #expect(parsed.recognitionTimeoutMs == AppConfig.defaultRecognitionTimeoutMs)
        #expect(parsed.syncTimeoutMs == AppConfig.defaultSyncTimeoutMs)
    }

    @Test("a timeout too large for an Int is capped instead of trapping")
    func hugeTimeoutIsCapped() {
        #expect(config([.syncTimeoutMs: "1e30"]).syncTimeoutMs == Int.max)
        #expect(config([.syncTimeoutMs: "9007199254740993"]).syncTimeoutMs == 9_007_199_254_740_992)
    }

    @Test("numeric plist values are read as numbers")
    func numericPlistValues() {
        #expect(config([.recognitionTimeoutMs: 30_000]).recognitionTimeoutMs == 30_000)
        #expect(config([.syncTimeoutMs: 2_500.5]).syncTimeoutMs == 2_500)
        #expect(config([.syncTimeoutMs: 0]).syncTimeoutMs == AppConfig.defaultSyncTimeoutMs)
        #expect(config([.syncTimeoutMs: Double.nan]).syncTimeoutMs == AppConfig.defaultSyncTimeoutMs)
    }

    @Test("a non-string value for a text setting counts as absent")
    func nonStringTextIsAbsent() {
        let parsed = config([
            .recognitionURL: 42, .recognitionKey: ["k"], .syncURL: 1.5, .syncKey: Data([1]),
            .householdOrigin: 7, .environment: 1,
        ], version: 2)
        #expect(parsed == AppConfig())
    }

    @Test("appVersion is CFBundleShortVersionString, or 0.0.0 without one")
    func appVersion() {
        #expect(config([:], version: "0.2.0").appVersion == "0.2.0")
        #expect(config([:]).appVersion == "0.0.0")
        #expect(config([:], version: "").appVersion == "0.0.0")
    }

    @Test("timeouts are also available as durations")
    func durations() {
        let parsed = AppConfig(recognitionTimeoutMs: 1_500, syncTimeoutMs: 60_000)
        #expect(parsed.recognitionTimeout == .milliseconds(1_500))
        #expect(parsed.syncTimeout == .seconds(60))
    }

    @Test("the info keys are the ones App/Resources/Info.plist declares")
    func infoKeyNames() {
        #expect(AppConfig.InfoKey.allCases.map(\.rawValue) == [
            "INVAppEnvironment", "INVRecognitionURL", "INVRecognitionKey", "INVRecognitionTimeoutMs",
            "INVSyncURL", "INVSyncKey", "INVSyncTimeoutMs", "INVHouseholdOrigin",
        ])
        #expect(AppConfig.Environment.allCases.map(\.rawValue) == ["development", "preview", "production"])
    }

    #if os(macOS)
    @Test("loads from a bundle's Info.plist")
    func loadsFromABundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppConfigTests-\(UUID().uuidString)/Probe.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.wystudio.inventory.probe-\(UUID().uuidString)",
            "CFBundleShortVersionString": "0.2.0",
            "INVAppEnvironment": "preview",
            "INVSyncURL": "https://sync.example/",
            "INVRecognitionTimeoutMs": "",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))

        let parsed = AppConfig.load(from: bundle)
        #expect(parsed.environment == .preview)
        #expect(parsed.syncEndpoint == "https://sync.example")
        #expect(parsed.recognitionTimeoutMs == 15_000)
        #expect(parsed.appVersion == "0.2.0")
    }
    #endif

    @Test("a bundle without the keys gives every default but the version")
    func bundleWithoutKeys() {
        let parsed = AppConfig.load(from: .module)
        #expect(parsed.recognitionEndpoint == nil)
        #expect(parsed.syncEndpoint == nil)
        #expect(parsed.environment == .development)
        #expect(parsed.householdOrigin == AppConfig.defaultHouseholdOrigin)
    }
}

@Suite("AppConfig parity (Fixtures/config.json)")
struct AppConfigParityTests {
    struct Unset: Decodable {
        let recognitionEndpoint: String?
        let recognitionKey: String?
        let recognitionTimeoutMs: Int
        let syncEndpoint: String?
        let syncKey: String?
        let syncTimeoutMs: Int
        let householdOrigin: String
        let environment: String
    }

    struct Text: Decodable {
        let input: String
        let recognitionEndpoint: String?
        let recognitionKey: String?
        let syncEndpoint: String?
        let syncKey: String?
        let householdOrigin: String
    }

    struct EnvironmentEntry: Decodable { let input: String; let environment: String }
    struct Timeout: Decodable { let input: String; let recognition: String; let sync: String }
    struct File: Decodable {
        let unset: Unset
        let text: [Text]
        let environments: [EnvironmentEntry]
        let timeouts: [Timeout]
    }

    /// What the native parser keeps of the number JS computed: whole positive milliseconds, else the default.
    static func native(_ js: String, default fallback: Int) -> Int {
        guard let value = Double(js), value.isFinite, value.rounded(.towardZero) > 0 else { return fallback }
        let whole = value.rounded(.towardZero)
        return whole < Double(Int.max) ? Int(whole) : Int.max
    }

    /// Both absent, or the same code points.
    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): sameScalars(a, b)
        default: false
        }
    }

    @Test("an empty Info.plist matches an unset environment")
    func unsetMatches() throws {
        let unset = try loadFixture("config", as: File.self).unset
        let parsed = AppConfig(infoDictionary: [:])
        #expect(parsed.recognitionEndpoint == unset.recognitionEndpoint)
        #expect(parsed.recognitionKey == unset.recognitionKey)
        #expect(parsed.recognitionTimeoutMs == unset.recognitionTimeoutMs)
        #expect(parsed.syncEndpoint == unset.syncEndpoint)
        #expect(parsed.syncKey == unset.syncKey)
        #expect(parsed.syncTimeoutMs == unset.syncTimeoutMs)
        #expect(parsed.householdOrigin == unset.householdOrigin)
        #expect(parsed.environment.rawValue == unset.environment)
    }

    @Test("text settings match config.ts code point for code point")
    func textMatches() throws {
        for entry in try loadFixture("config", as: File.self).text {
            let parsed = allText(entry.input)
            let label = scalarDump(entry.input)
            #expect(Self.same(parsed.recognitionEndpoint, entry.recognitionEndpoint), "\(label)")
            #expect(Self.same(parsed.recognitionKey, entry.recognitionKey), "\(label)")
            #expect(Self.same(parsed.syncEndpoint, entry.syncEndpoint), "\(label)")
            #expect(Self.same(parsed.syncKey, entry.syncKey), "\(label)")
            #expect(sameScalars(parsed.householdOrigin, entry.householdOrigin), "\(label)")
        }
    }

    @Test("the environment matches config.ts")
    func environmentMatches() throws {
        for entry in try loadFixture("config", as: File.self).environments {
            #expect(config([.environment: entry.input]).environment.rawValue == entry.environment, "\(scalarDump(entry.input))")
        }
    }

    @Test("timeouts match config.ts wherever its number is usable, and fall back where it is not")
    func timeoutsMatch() throws {
        var usable = 0
        for entry in try loadFixture("config", as: File.self).timeouts {
            let parsed = config([.recognitionTimeoutMs: entry.input, .syncTimeoutMs: entry.input])
            let label = scalarDump(entry.input)
            #expect(parsed.recognitionTimeoutMs == Self.native(entry.recognition, default: 15_000), "\(label) JS \(entry.recognition)")
            #expect(parsed.syncTimeoutMs == Self.native(entry.sync, default: 60_000), "\(label) JS \(entry.sync)")
            if let value = Double(entry.sync), value.isFinite, value >= 1 { usable += 1 }
        }
        #expect(usable >= 10)
    }
}

/// The committed build configuration, read the way Xcode reads it: `//` starts a
/// comment, `$()` expands to nothing, and an undefined `$(VAR)` to an empty string.
/// Optional includes (`Secrets.xcconfig`, `Local.xcconfig`) are gitignored and skipped.
@Suite("AppConfig build settings (Config/*.xcconfig, App/Resources/Info.plist)", .enabled(if: BuildFiles.present))
struct AppConfigBuildSettingsTests {
    @Test("Info.plist sets every key from its INV_ build setting")
    func infoPlistKeys() throws {
        let plist = try BuildFiles.infoPlist()
        let expected: [AppConfig.InfoKey: String] = [
            .environment: "INV_APP_ENV",
            .recognitionURL: "INV_RECOGNITION_URL",
            .recognitionKey: "INV_RECOGNITION_KEY",
            .recognitionTimeoutMs: "INV_RECOGNITION_TIMEOUT_MS",
            .syncURL: "INV_SYNC_URL",
            .syncKey: "INV_SYNC_KEY",
            .syncTimeoutMs: "INV_SYNC_TIMEOUT_MS",
            .householdOrigin: "INV_HOUSEHOLD_ORIGIN",
        ]
        for key in AppConfig.InfoKey.allCases {
            #expect(plist[key.rawValue] as? String == "$(\(expected[key] ?? ""))", "\(key.rawValue)")
        }
    }

    @Test("the https:/$()/ form resolves to https:// and every configuration parses", arguments: [
        ("Debug", AppConfig.Environment.development),
        ("Preview", .preview),
        ("Release", .production),
    ])
    func configurations(name: String, environment: AppConfig.Environment) throws {
        let parsed = AppConfig(infoDictionary: try BuildFiles.expandedInfo(configuration: name))
        #expect(parsed.environment == environment)
        // DECISIONS U1: every configuration, Preview included, uses the production endpoints.
        #expect(parsed.recognitionEndpoint == "https://server-wy-studio.vercel.app/api/recognize")
        #expect(parsed.syncEndpoint == "https://inventory-sync.wyachou95.workers.dev")
        #expect(parsed.householdOrigin == AppConfig.defaultHouseholdOrigin)
        #expect(parsed.recognitionTimeoutMs == 15_000)
        #expect(parsed.syncTimeoutMs == 60_000)
        // The committed files never carry the keys (Secrets.xcconfig does).
        #expect(parsed.recognitionKey == nil)
        #expect(parsed.syncKey == nil)
    }
}

private enum BuildFiles {
    /// native-ios/, six levels above this file.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static var present: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Resources/Info.plist").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("Config/Shared.xcconfig").path)
    }

    static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The build settings an xcconfig defines, following its non-optional includes in order.
    static func settings(_ name: String) throws -> [String: String] {
        let text = try String(contentsOf: root.appendingPathComponent("Config/\(name)"), encoding: .utf8)
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include?") { continue }
            if line.hasPrefix("#include") {
                let included = line.components(separatedBy: "\"").dropFirst().first ?? ""
                result.merge(try settings(included)) { _, new in new }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[key] = value.replacingOccurrences(of: "$()", with: "")
        }
        return result
    }

    /// Info.plist with `$(VAR)` references expanded for one configuration.
    static func expandedInfo(configuration: String) throws -> [String: Any] {
        let values = try settings("\(configuration).xcconfig")
        var info: [String: Any] = [:]
        for (key, value) in try infoPlist() {
            guard let text = value as? String, text.hasPrefix("$("), text.hasSuffix(")") else {
                info[key] = value
                continue
            }
            let variable = String(text.dropFirst(2).dropLast())
            info[key] = values[variable] ?? ""
        }
        return info
    }
}

import Foundation

// RN: src/services/config.ts and src/services/appInfo.ts. The RN build inlined
// `EXPO_PUBLIC_*` variables; the native build reads custom Info.plist keys that the
// xcconfigs fill (Config/*.xcconfig → App/Resources/Info.plist). Everything here
// ships inside the app and is public by design, the shared app keys included
// (09 §8.3): never log or print them anyway (09 §11).

/// Environment-specific configuration (RN `appConfig`) and the app version (RN `appVersion`).
public struct AppConfig: Sendable, Hashable {
    /// Which build this is (RN `EXPO_PUBLIC_ENV`). Settings shows the raw value.
    public enum Environment: String, Sendable, Hashable, CaseIterable {
        case development
        case preview
        case production
    }

    /// The Info.plist keys the configuration comes from, each set to an `$(INV_…)` build setting.
    public enum InfoKey: String, Sendable, CaseIterable {
        case environment = "INVAppEnvironment"
        case recognitionURL = "INVRecognitionURL"
        case recognitionKey = "INVRecognitionKey"
        case recognitionTimeoutMs = "INVRecognitionTimeoutMs"
        case syncURL = "INVSyncURL"
        case syncKey = "INVSyncKey"
        case syncTimeoutMs = "INVSyncTimeoutMs"
        case householdOrigin = "INVHouseholdOrigin"
    }

    public static let defaultRecognitionTimeoutMs = 15_000
    public static let defaultSyncTimeoutMs = 60_000
    public static let defaultHouseholdOrigin = "https://inventory.wystudio.be"
    /// What Settings shows when the bundle has no version (RN `?? '0.0.0'`).
    public static let defaultAppVersion = "0.0.0"

    /// Full recognition URL, path included, or nil when photo suggestions are off.
    public var recognitionEndpoint: String?
    /// Recognition's `x-inventory-key`; nil sends no header.
    public var recognitionKey: String?
    /// Total wall-clock budget for one recognition request, in milliseconds.
    public var recognitionTimeoutMs: Int
    /// Base URL of the photo and backup service, without trailing slashes, or nil when backup is unavailable.
    public var syncEndpoint: String?
    /// Sync's `x-inventory-key`; nil sends no header.
    public var syncKey: String?
    /// Total wall-clock budget for one sync request, in milliseconds.
    public var syncTimeoutMs: Int
    /// Where pairing goes, without trailing slashes. Once paired, requests use the session's origin.
    public var householdOrigin: String
    public var environment: Environment
    /// Marketing version shown in Settings and the privacy notice (RN `appVersion`).
    public var appVersion: String

    public init(
        recognitionEndpoint: String? = nil,
        recognitionKey: String? = nil,
        recognitionTimeoutMs: Int = AppConfig.defaultRecognitionTimeoutMs,
        syncEndpoint: String? = nil,
        syncKey: String? = nil,
        syncTimeoutMs: Int = AppConfig.defaultSyncTimeoutMs,
        householdOrigin: String = AppConfig.defaultHouseholdOrigin,
        environment: Environment = .development,
        appVersion: String = AppConfig.defaultAppVersion
    ) {
        self.recognitionEndpoint = recognitionEndpoint
        self.recognitionKey = recognitionKey
        self.recognitionTimeoutMs = recognitionTimeoutMs
        self.syncEndpoint = syncEndpoint
        self.syncKey = syncKey
        self.syncTimeoutMs = syncTimeoutMs
        self.householdOrigin = householdOrigin
        self.environment = environment
        self.appVersion = appVersion
    }

    /// Parses an Info.plist dictionary with the RN rules (09 §8.1).
    ///
    /// - Strings are trimmed with JS `trim()`, and empty means absent: an unset
    ///   xcconfig variable expands to `""`.
    /// - The sync URL and the household origin also lose trailing `/`s; the
    ///   recognition URL keeps them, being a full URL with its path.
    /// - The environment must be exactly `production` or `preview`; anything else
    ///   is `development`.
    /// - A timeout goes through JS `Number()`. Where RN would keep 0, NaN or a
    ///   negative (all of which abort the request at once), this falls back to the
    ///   default instead (00-index §5, 09 §15 Q14). A fraction is truncated to whole
    ///   milliseconds, so anything below 1 ms falls back too; a value beyond `Int`,
    ///   `Infinity` included, is capped at `Int.max` (RN never aborts it).
    public init(infoDictionary info: [String: Any]) {
        func value(_ key: InfoKey) -> Any? { info[key.rawValue] }
        self.init(
            recognitionEndpoint: Self.trimmed(value(.recognitionURL)),
            recognitionKey: Self.trimmed(value(.recognitionKey)),
            recognitionTimeoutMs: Self.milliseconds(value(.recognitionTimeoutMs), default: Self.defaultRecognitionTimeoutMs),
            syncEndpoint: Self.origin(value(.syncURL)),
            syncKey: Self.trimmed(value(.syncKey)),
            syncTimeoutMs: Self.milliseconds(value(.syncTimeoutMs), default: Self.defaultSyncTimeoutMs),
            householdOrigin: Self.origin(value(.householdOrigin)) ?? Self.defaultHouseholdOrigin,
            environment: Self.environment(value(.environment)),
            appVersion: Self.version(info["CFBundleShortVersionString"])
        )
    }

    /// The configuration in `bundle`'s Info.plist; with no Info.plist, every default.
    public static func load(from bundle: Bundle = .main) -> AppConfig {
        AppConfig(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// ``recognitionTimeoutMs`` as a `Duration`.
    public var recognitionTimeout: Duration { .milliseconds(recognitionTimeoutMs) }

    /// ``syncTimeoutMs`` as a `Duration`.
    public var syncTimeout: Duration { .milliseconds(syncTimeoutMs) }
}

// MARK: - Parse rules

extension AppConfig {
    /// `value?.trim() || null` (config.ts:66-67,70).
    static func trimmed(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.jsTrimmed()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `value?.trim().replace(/\/+$/, '') || null` (config.ts:69,72-73). White space
    /// before the slashes stays, as in JS: `"https://a.example /"` keeps its space.
    static func origin(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let scalars = text.jsTrimmed().unicodeScalars
        guard let last = scalars.lastIndex(where: { $0 != "/" }) else { return nil }
        return String(scalars[...last])
    }

    /// `'production'` or `'preview'` exactly, else `'development'` (config.ts:59-63).
    static func environment(_ raw: Any?) -> Environment {
        guard let text = raw as? String else { return .development }
        for candidate in [Environment.production, .preview] where text.utf8.elementsEqual(candidate.rawValue.utf8) {
            return candidate
        }
        return .development
    }

    /// `Number(value ?? fallback)` (config.ts:68,71), with the native fallback for unusable values.
    ///
    /// Only an empty, non-numeric (NaN) or non-positive value falls back (00-index §5). A
    /// value too large for an `Int`, `Infinity` included, is capped at `Int.max`: RN's timer
    /// for it never fires, so the request is never aborted, and `Int.max` milliseconds
    /// keeps that.
    static func milliseconds(_ raw: Any?, default fallback: Int) -> Int {
        let number: Double? = switch raw {
        case let text as String: jsNumber(text.jsTrimmed())
        case let whole as Int: Double(whole)
        case let real as Double: real
        default: nil
        }
        guard let number, !number.isNaN else { return fallback }
        let whole = number.rounded(.towardZero)
        guard whole > 0 else { return fallback }
        return whole < Double(Int.max) ? Int(whole) : Int.max
    }

    /// `CFBundleShortVersionString`, or `0.0.0` when it is missing or empty (appInfo.ts:4).
    static func version(_ raw: Any?) -> String {
        guard let text = raw as? String, !text.isEmpty else { return defaultAppVersion }
        return text
    }
}

// MARK: - Printing

// 09 §11: an `x-inventory-key` never goes into a log. The synthesized description
// and mirror would print both keys for `"\(config)"`, `print` or `dump`, so they
// only say whether a key is set.
extension AppConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AppConfig(environment: \(environment.rawValue), appVersion: \(appVersion), "
            + "recognitionEndpoint: \(recognitionEndpoint ?? "nil"), recognitionKey: \(Self.redacted(recognitionKey)), "
            + "recognitionTimeoutMs: \(recognitionTimeoutMs), syncEndpoint: \(syncEndpoint ?? "nil"), "
            + "syncKey: \(Self.redacted(syncKey)), syncTimeoutMs: \(syncTimeoutMs), householdOrigin: \(householdOrigin))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "recognitionEndpoint": recognitionEndpoint as Any,
                "recognitionKey": Self.redacted(recognitionKey),
                "recognitionTimeoutMs": recognitionTimeoutMs,
                "syncEndpoint": syncEndpoint as Any,
                "syncKey": Self.redacted(syncKey),
                "syncTimeoutMs": syncTimeoutMs,
                "householdOrigin": householdOrigin,
                "environment": environment,
                "appVersion": appVersion,
            ],
            displayStyle: .struct
        )
    }

    private static func redacted(_ key: String?) -> String {
        key == nil ? "nil" : "<set>"
    }
}

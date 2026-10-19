import Foundation
import Synchronization

/// Resolves catalog keys for `L10n` and `Format`.
///
/// Every lookup goes through `Bundle.module`. Xcode compiles Localizable.xcstrings
/// into the app; the SwiftPM command line only copies it, so under `swift test`
/// every lookup misses and the English fallback is used. The fallback is the exact
/// strings.ts output (plural variants resolved here), so both paths give the same
/// text. See native-ios/scripts/strings/README.md.
enum L10nRuntime {
    static let bundle: Bundle = .module

    /// Arguments are formatted like JS template literals: ASCII digits, no grouping
    /// separator. Foundation also takes the plural rule from this locale, so English
    /// `one` (exactly 1) applies whatever the device locale. Revisit when the app is
    /// localised.
    static let locale = Locale(identifier: "en_US_POSIX")

    /// One `%n$#@name@` token of a format: the count is argument `argNum` (1-based),
    /// and `%arg` in a variant stands for it.
    struct Substitution: Sendable {
        let name: String
        let argNum: Int
        let one: String
        let other: String

        init(_ name: String, _ argNum: Int, one: String, other: String) {
            self.name = name
            self.argNum = argNum
            self.one = one
            self.other = other
        }
    }

    static func text(_ key: String, _ english: String) -> String {
        resolve(key) { english }
    }

    static func format(_ key: String, _ english: String, _ args: [any CVarArg]) -> String {
        String(format: resolve(key) { english }, locale: locale, arguments: args)
    }

    /// A sentence that a single count decides (catalog plural variations).
    static func plural(_ key: String, one: String, other: String, _ count: Int) -> String {
        String(format: resolve(key) { count == 1 ? one : other }, locale: locale, arguments: [count])
    }

    /// A format whose counts each pick their own wording (catalog substitutions).
    static func substitutions(_ key: String, _ english: String, _ subs: [Substitution], _ args: [any CVarArg]) -> String {
        String(format: resolve(key) { expand(english, subs, args) }, locale: locale, arguments: args)
    }

    /// Exact equality, as JS `===` on strings. Swift `==` treats canonically
    /// equivalent strings as equal.
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// The English format with each substitution replaced by its variant for the
    /// count it refers to, which is what Foundation does with a compiled catalog.
    static func expand(_ format: String, _ subs: [Substitution], _ args: [any CVarArg]) -> String {
        subs.reduce(format) { result, sub in
            let count = args.indices.contains(sub.argNum - 1) ? args[sub.argNum - 1] as? Int : nil
            let variant = (count == 1 ? sub.one : sub.other)
                .replacingOccurrences(of: "%arg", with: "%\(sub.argNum)$lld")
            return result.replacingOccurrences(of: "%\(sub.argNum)$#@\(sub.name)@", with: variant)
        }
    }

    private static let missing = "\u{0}missing"

    private static func resolve(_ key: String, fallback: () -> String) -> String {
        let active = override
        active?.log?.record(key)
        let found = (active?.bundle ?? bundle).localizedString(forKey: key, value: missing, table: nil)
        if found != missing { return found }
        if active?.strict == true { return "[no catalog entry for \(key)]" }
        return fallback()
    }

    // MARK: Test hook

    /// Resolves against another bundle (tests use a catalog compiled by
    /// xcstringstool), optionally without the English fallback, recording the keys.
    struct Override: Sendable {
        var bundle: Bundle
        var strict: Bool
        var log: KeyLog?
    }

    @TaskLocal static var override: Override?

    /// The catalog keys resolved while an `Override` was active.
    final class KeyLog: Sendable {
        private let storage = Mutex<Set<String>>([])

        func record(_ key: String) {
            storage.withLock { _ = $0.insert(key) }
        }

        var keys: Set<String> {
            storage.withLock { $0 }
        }
    }
}

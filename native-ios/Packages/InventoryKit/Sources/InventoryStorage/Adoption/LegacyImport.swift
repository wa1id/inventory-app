import Foundation

/// The one-time copy of the React Native build's seven AsyncStorage preferences into
/// `UserDefaults` (DECISIONS D-5, 02 §5.4).
///
/// Values are copied verbatim as strings under the same key names; readers parse them on read
/// with RN's rules. A key that already has a native value is never overwritten. The RN directory
/// is left in place. The Int marker `native.legacyImport.v1` is set only after a successful read,
/// so a locked or unreadable store is retried next launch.
///
/// Run it before anything reads these preferences (09 §3.2 step 2a), after
/// ``ProtectedData/waitUntilAvailable()`` (02 §8 step 0). It also checks protected data itself and
/// does nothing while it is unavailable.
@MainActor
public struct LegacyImport {
    /// Set to 1 once the import has run. An Int, not a Bool.
    public static let markerKey = "native.legacyImport.v1"
    /// Left in the standard domain by expo-system-ui on every RN launch; meaningless natively (02 §6).
    static let expoSystemUIBackgroundColorKey = "ExpoSystemUI.backgroundColor"

    /// What a run did.
    public enum Outcome: Equatable, Sendable {
        /// The marker was already set; nothing was read.
        case alreadyImported
        /// Protected data is not available yet; nothing was read and the marker stays unset.
        case protectedDataUnavailable
        /// The RN store could not be read; the marker stays unset so the next launch retries.
        case failed(LegacyAsyncStorageReader.Failure)
        /// The import finished; `keys` are the preferences it copied (possibly none).
        case imported(keys: [String])
    }

    private let defaults: UserDefaults
    private let reader: LegacyAsyncStorageReader
    private let isProtectedDataAvailable: @MainActor () -> Bool

    /// - Parameters:
    ///   - defaults: Where the values go; `.standard` in the app, a suite in tests.
    ///   - reader: The RN store to read.
    ///   - isProtectedDataAvailable: Whether the data-protected manifest is readable yet.
    public init(
        defaults: UserDefaults = .standard,
        reader: LegacyAsyncStorageReader = LegacyAsyncStorageReader(),
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { ProtectedData.isAvailable }
    ) {
        self.defaults = defaults
        self.reader = reader
        self.isProtectedDataAvailable = isProtectedDataAvailable
    }

    /// Imports the RN preferences unless that has already happened. Cheap and synchronous.
    @discardableResult
    public func runIfNeeded() -> Outcome {
        guard defaults.integer(forKey: Self.markerKey) < 1 else { return .alreadyImported }
        // Before the first unlock the manifest is unreadable (02 §1); try again later.
        guard isProtectedDataAvailable() else { return .protectedDataUnavailable }
        let legacy: [String: String]
        do {
            legacy = try reader.readAll()
        } catch {
            return .failed(error)
        }
        var copied: [String] = []
        for key in PreferenceKey.legacyKeys where defaults.object(forKey: key) == nil {
            guard let value = legacy[key] else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        defaults.removeObject(forKey: Self.expoSystemUIBackgroundColorKey)
        defaults.set(1, forKey: Self.markerKey)
        return .imported(keys: copied)
    }
}

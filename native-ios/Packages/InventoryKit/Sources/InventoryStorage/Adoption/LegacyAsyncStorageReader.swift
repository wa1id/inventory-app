import CryptoKit
import Foundation

/// Reads the values the React Native build kept in AsyncStorage (02 §5.2).
///
/// The app used the default export of @react-native-async-storage/async-storage 3.1.1, which is
/// the legacy v2 store: `manifest.json` in
/// `Library/Application Support/<bundle id>/RCTAsyncLocalStorage_V1/`, a JSON object mapping each
/// key to its value, or to `null` when the value was longer than 1024 UTF-16 units and lives in a
/// sibling file named by the lowercase hex MD5 of the key.
/// RN: node_modules/@react-native-async-storage/async-storage/apple/legacy_storage/RNCAsyncStorage.mm.
///
/// Read-only: the directory is never modified, so an RN TestFlight build installed over the native
/// one still finds it (DECISIONS U11).
public struct LegacyAsyncStorageReader: Sendable {
    /// Why the stored values could not be read. RN would fail the read the same way and fall back
    /// to defaults for that launch.
    public enum Failure: Error, Equatable, Sendable {
        /// The manifest exists but could not be read (for example data protection before the
        /// first unlock). Carries the underlying error's description.
        case unreadableManifest(String)
        /// The manifest is not UTF-8 text.
        case manifestNotUTF8
        /// An overflow value file exists but could not be read as UTF-8 (RNCAsyncStorage.mm:82-110).
        case unreadableValue(key: String)
    }

    /// `Library/Application Support/<bundle id>/RCTAsyncLocalStorage_V1` (RNCAsyncStorage.mm:129-151).
    public let directory: URL
    /// `Documents/RCTAsyncLocalStorage_V1`, which RN copies forward when the Application Support
    /// directory does not exist yet (RNCAsyncStorage.mm:455-459, 404-409). Read only in that case.
    public let legacyDirectory: URL

    /// - Parameters:
    ///   - applicationSupport: The container's `Library/Application Support`.
    ///   - documents: The container's `Documents`.
    ///   - bundleIdentifier: The app's bundle id; the RN build used `com.wystudio.inventory`.
    public init(
        applicationSupport: URL = .applicationSupportDirectory,
        documents: URL = .documentsDirectory,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.wystudio.inventory"
    ) {
        directory = applicationSupport
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: Self.directoryName, directoryHint: .isDirectory)
        legacyDirectory = documents.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    static let directoryName = "RCTAsyncLocalStorage_V1"
    static let manifestName = "manifest.json"

    /// Every stored key and value. Empty when the RN app never wrote anything or the manifest is
    /// not a JSON object (RN then starts a new store, RNCAsyncStorage.mm:555-561).
    ///
    /// Throws when the manifest, or an overflow file that exists, cannot be read. An overflow file
    /// that is missing means the key is absent (RNCAsyncStorage.mm:598-617).
    public func readAll() throws(Failure) -> [String: String] {
        try read(only: nil)
    }

    /// The stored values of `keys`; keys with no value are left out.
    ///
    /// Like RN's `multiGet` (RNCAsyncStorage.mm:673-703), only the requested keys are read, so
    /// another key's unreadable overflow file cannot fail the read. Throws when the manifest, or
    /// the overflow file of a requested key that exists, cannot be read.
    public func read(keys: [String]) throws(Failure) -> [String: String] {
        try read(only: keys)
    }

    private func read(only requested: [String]?) throws(Failure) -> [String: String] {
        let fileManager = FileManager.default
        let storeDirectory = isDirectory(directory) || !isDirectory(legacyDirectory) ? directory : legacyDirectory
        let manifestURL = storeDirectory.appending(path: Self.manifestName, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw .unreadableManifest(String(describing: error))
        }
        guard String(data: data, encoding: .utf8) != nil else { throw .manifestNotUTF8 }
        // RN parses with NSJSONSerialization, fragments allowed (RCTUtils.mm:129-185). Kept as an
        // NSDictionary, so keys compare by UTF-16 code units as RN's do: bridging to
        // [String: Any] would trap on two keys that are canonically equivalent Swift strings.
        guard let manifest = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
            as? NSDictionary
        else { return [:] }

        var values: [String: String] = [:]
        for key in requested ?? manifest.allKeys.compactMap({ $0 as? String }) {
            guard let raw = manifest.object(forKey: key) else { continue }
            if let string = raw as? String {
                values[key] = string
            } else if raw is NSNull {
                let file = storeDirectory.appending(path: Self.md5Hex(key), directoryHint: .notDirectory)
                guard fileManager.fileExists(atPath: file.path) else { continue }
                guard let fileData = try? Data(contentsOf: file),
                      let string = String(data: fileData, encoding: .utf8)
                else { throw .unreadableValue(key: key) }
                values[key] = string
            }
        }
        return values
    }

    /// `RCTMD5Hash`: the lowercase hex MD5 of the key's UTF-8 bytes (RCTUtils.mm:256-282).
    public static func md5Hex(_ key: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

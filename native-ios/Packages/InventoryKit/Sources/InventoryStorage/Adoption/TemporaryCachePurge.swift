import Foundation

/// Removes the temporary files the React Native build left in `Library/Caches` (DECISIONS U11,
/// 02 §3.5): the `ImageManipulator`, `Camera` and `ImagePicker` directories and the QR label share
/// pictures `label-*.png`. Nothing references them. Nothing else is touched: not
/// `household-photos`, not `Documents/item-photos`, not the RN AsyncStorage directory.
public struct TemporaryCachePurge: Sendable {
    /// Set to 1 once the purge has run on this install.
    public static let markerKey = "native.cachePurge.v1"

    /// Written by expo-image-manipulator, expo-camera and expo-image-picker.
    static let directoryNames = ["ImageManipulator", "Camera", "ImagePicker"]

    /// The container's `Library/Caches` directory.
    public let caches: URL

    public init(caches: URL = .cachesDirectory) {
        self.caches = caches
    }

    /// Runs ``purge()`` once per install (on the first native launch), then never again.
    /// Run it after protected data is available, off the main thread (02 §8 step 5).
    @discardableResult
    public func runIfNeeded(defaults: UserDefaults = .standard) -> [URL] {
        guard defaults.integer(forKey: Self.markerKey) < 1 else { return [] }
        let removed = purge()
        defaults.set(1, forKey: Self.markerKey)
        return removed
    }

    /// Deletes the RN temporaries that exist and returns what was removed. Best effort: an item
    /// that cannot be deleted is skipped.
    @discardableResult
    public func purge() -> [URL] {
        let fileManager = FileManager.default
        var targets = Self.directoryNames.map { caches.appending(path: $0, directoryHint: .isDirectory) }
        let entries = (try? fileManager.contentsOfDirectory(atPath: caches.path)) ?? []
        // RN: src/ui/container/labelImage.ts:46 names them `label-<code>.png`.
        targets += entries.sorted()
            .filter { $0.hasPrefix("label-") && $0.hasSuffix(".png") }
            .map { caches.appending(path: $0, directoryHint: .notDirectory) }
        return targets.filter { target in
            fileManager.fileExists(atPath: target.path) && (try? fileManager.removeItem(at: target)) != nil
        }
    }
}

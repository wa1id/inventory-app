import Foundation

/// A throwaway directory, deleted when the value goes away.
///
/// It doubles as a stand-in app data container: ``documents``, ``caches`` and
/// ``applicationSupport`` are where iOS would put them under the container root, so code that
/// takes those URLs never touches the real ones. Nothing is created until a test writes.
public final class TemporaryDirectory: Sendable {
    public let root: URL

    /// Creates a fresh, empty directory under the system temporary directory.
    public init(prefix: String = "inventory-tests") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// `Documents/` under the root.
    public var documents: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
    /// `Library/Caches/` under the root.
    public var caches: URL { root.appending(path: "Library/Caches", directoryHint: .isDirectory) }
    /// `Library/Application Support/` under the root.
    public var applicationSupport: URL { root.appending(path: "Library/Application Support", directoryHint: .isDirectory) }

    /// The URL of `relativePath` under the root.
    public func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    /// The file-system path of the file `relativePath` under the root.
    public func path(_ relativePath: String) -> String {
        root.appending(path: relativePath, directoryHint: .notDirectory).path
    }

    /// Writes `data` at `relativePath`, creating the directories on the way.
    @discardableResult
    public func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Creates the directory `relativePath` (and its parents).
    @discardableResult
    public func createDirectory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether anything exists at `relativePath`.
    public func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    /// The names in the directory `relativePath` (the root by default), sorted; empty when it does not exist.
    public func contents(of relativePath: String = "") -> [String] {
        let directory = relativePath.isEmpty ? root : root.appending(path: relativePath, directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

import Foundation
import Testing

/// Loads the parity vectors and fixtures in `Fixtures/adoption`. The JSON vectors were generated
/// by running the real TypeScript (see `Fixtures/adoption/README.md`).
enum AdoptionFixtures {
    static var directory: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "adoption", withExtension: nil, subdirectory: "Fixtures"))
        }
    }

    static func url(_ name: String) throws -> URL {
        try directory.appending(path: name)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url(name)))
    }
}

/// A throwaway directory standing in for an app data container.
final class TemporaryContainer {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "adoption-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var documents: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
    var caches: URL { root.appending(path: "Library/Caches", directoryHint: .isDirectory) }
    var applicationSupport: URL { root.appending(path: "Library/Application Support", directoryHint: .isDirectory) }

    /// Writes `data` at `relativePath`, creating the directories on the way.
    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func createDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: relativePath, directoryHint: .isDirectory), withIntermediateDirectories: true)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relativePath).path)
    }
}

/// A throwaway `UserDefaults` suite, removed when the value goes away.
final class TemporaryDefaults {
    let name: String
    let defaults: UserDefaults

    init() throws {
        name = "inventory.adoption.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

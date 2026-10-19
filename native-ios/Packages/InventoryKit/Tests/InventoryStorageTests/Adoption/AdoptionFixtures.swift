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


import Foundation
@testable import InventoryStrings

/// One argument of a parity case, tagged with its TS type in the JSON.
enum ParityArg: Decodable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey {
        case int, string, bool
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int.self, forKey: .int) {
            self = .int(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else {
            self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): String(reflecting: value)
        case .bool(let value): String(value)
        }
    }
}

enum ParityError: Error {
    case unknownPath(String)
    case argument(index: Int, expected: String)
}

extension [ParityArg] {
    func int(_ index: Int) throws -> Int {
        guard indices.contains(index), case .int(let value) = self[index] else {
            throw ParityError.argument(index: index, expected: "int")
        }
        return value
    }

    func string(_ index: Int) throws -> String {
        guard indices.contains(index), case .string(let value) = self[index] else {
            throw ParityError.argument(index: index, expected: "string")
        }
        return value
    }

    func bool(_ index: Int) throws -> Bool {
        guard indices.contains(index), case .bool(let value) = self[index] else {
            throw ParityError.argument(index: index, expected: "bool")
        }
        return value
    }
}

/// Fixtures/strings-parity.json, written by native-ios/scripts/strings/generate.mjs
/// from the real strings.ts and format.ts.
struct StringsFixture: Decodable, Sendable {
    struct Case: Decodable, Sendable {
        let args: [ParityArg]
        let expected: String?
    }

    struct Entry: Decodable, Sendable {
        let path: String
        let kind: String
        let cases: [Case]
    }

    struct Plural: Decodable, Sendable {
        let count: Int
        let one: String
        let other: String
        let expected: String
    }

    struct SentenceList: Decodable, Sendable {
        let parts: [String]
        let expected: String
    }

    struct Ago: Decodable, Sendable {
        let ms: Int64
        let now: Int64
        let expected: String
    }

    struct LongDate: Decodable, Sendable {
        let ms: Int64
        let timeZone: String
        let expected: String
    }

    struct FormatVectors: Decodable, Sendable {
        let plural: [Plural]
        let sentenceList: [SentenceList]
        let ago: [Ago]
        let longDate: [LongDate]
    }

    let catalogKeys: [String]
    let entries: [Entry]
    let format: FormatVectors

    static let shared: StringsFixture = {
        let url = Bundle.module.url(forResource: "strings-parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(StringsFixture.self, from: Data(contentsOf: url))
    }()
}

/// A bundle with no Localizable table: the test target's own, which holds only
/// Fixtures. Every lookup in it misses, so the English fallback answers.
enum NoCatalog {
    static var bundle: Bundle { .module }

    static var holdsNoCatalog: Bool {
        ["strings", "stringsdict", "xcstrings"].allSatisfy {
            bundle.url(forResource: "Localizable", withExtension: $0) == nil
        }
    }
}

/// The source Localizable.xcstrings, read from the checkout.
enum CatalogSource {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/InventoryStrings/Resources/Localizable.xcstrings")
}

#if os(macOS)
/// Localizable.xcstrings compiled by Xcode's own `xcstringstool` into a throwaway
/// bundle: the same .strings and .stringsdict files Xcode puts in the app.
enum CompiledCatalog {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let result: Result<Compiled, any Error> = Result { try compile() }

    struct Compiled: Sendable {
        let bundle: Bundle
        let directory: URL
        let log: String
    }

    private static func compile() throws -> Compiled {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("InventoryStrings-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcstringstool", "compile", CatalogSource.url.path, "--output-directory", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "xcstringstool failed (\(process.terminationStatus)): \(log)")
        }
        guard let bundle = Bundle(url: output) else {
            throw Failure(description: "no bundle at \(output.path)")
        }
        return Compiled(bundle: bundle, directory: output, log: log)
    }
}
#endif

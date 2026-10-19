import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

// Write parity with the TypeScript repositories the home server runs (DECISIONS U12).
//
// `Fixtures/db/writes.json` is one script of repository writes (trims, folds, NULL
// patches, drop-zone guards, conflicts, foreign-key failures, the short-code retry,
// tag reuse, photo replacement, QR rebinding, cascades) that the generator ran
// through the real TypeScript repositories with a seeded clock, seeded id bytes and
// seeded short codes, recording every result, every error, a dump of every table,
// and searches over what the writes stored. This suite replays the script through
// the Swift repositories with the same seeds. Ids and timestamps only line up if
// Swift reads the clock and the random source at exactly the points the TS does,
// so the dumps compare whole rows, byte for byte.

/// A JSON value as `JSON.stringify` wrote it. Objects compare without their `null`
/// members (TS writes `null`, Swift's synthesized `Codable` omits `nil`), strings by
/// code points, and numbers by value.
indirect enum ScriptJSON: Decodable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ScriptJSON])
    case object([String: ScriptJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ScriptJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ScriptJSON].self))
        }
    }

    /// The JSON a Swift value encodes to.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(ScriptJSON.self, from: JSONEncoder().encode(value))
    }

    static func == (lhs: ScriptJSON, rhs: ScriptJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): Double(a) == b
        case let (.double(a), .double(b)): a == b
        case let (.string(a), .string(b)): a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.filter { $0.value != .null } == b.filter { $0.value != .null }
        default: false
        }
    }

    subscript(key: String) -> ScriptJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        switch self {
        case .int(let value): Int(exactly: value)
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }

    /// The value as `node:sqlite` returned it from a column.
    var scalar: SQLScalar {
        switch self {
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .string(let value): .string(value)
        case .bool(let value): .int(value ? 1 : 0)
        default: .null
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let value): "\(value)"
        case .int(let value): "\(value)"
        case .double(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .array(let values): "[\(values.map(\.description).joined(separator: ", "))]"
        case .object(let members):
            "{\(members.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))}"
        }
    }
}

/// The generator's `lcg(seed)`: `state = state * 1664525 + 1013904223 (mod 2^32)`, then `state / 2^32`.
private final class SeededLCG: Sendable {
    private let state: Locked<UInt32>

    init(seed: UInt32) {
        state = Locked(seed)
    }

    func next() -> UInt32 {
        state.update { value in
            value = value &* 1_664_525 &+ 1_013_904_223
            return value
        }
    }
}

/// `configureRandomBytes((n) => … Math.floor(lcg() * 256))`: the top byte of each LCG state.
private struct SeededBytes: RandomByteSource {
    let lcg: SeededLCG

    func randomBytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(lcg.next() >> 24) }
    }
}

struct WriteScript: Decodable {
    struct Seeds: Decodable {
        let clockStart: Int64
        let clockStep: Int64
        let idSeed: UInt32
        let codeSeed: UInt32
    }

    let seeds: Seeds
    let steps: [ScriptJSON]
    let tables: [String: [[String: ScriptJSON]]]

    static func load() throws -> WriteScript {
        try DatabaseFixtures.decode(WriteScript.self, from: "writes.json")
    }

    /// Repositories over a fresh migrated database, with the generator's clock, id bytes and short codes.
    func makeRepositories() throws -> LocalRepositories {
        let clock = Locked(seeds.clockStart)
        let step = seeds.clockStep
        let bytes = SeededBytes(lcg: SeededLCG(seed: seeds.idSeed))
        let codes = SeededLCG(seed: seeds.codeSeed)
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        let environment = RepositoryEnvironment(
            now: {
                clock.update { value in
                    value += step
                    return value
                }
            },
            randomBytes: bytes,
            // RN `generateShortCode` with `Math.random` = the LCG: `ALPHABET[floor(r * 32)]`.
            shortCode: { type in
                let suffix = (0..<4).map { _ in alphabet[Int(codes.next() >> 27)] }
                return "\(type.shortCodePrefix)-\(String(suffix))"
            }
        )
        return try freshRepos(environment: environment)
    }
}

/// What one step produced.
private enum Outcome: Equatable, CustomStringConvertible {
    case ok(ScriptJSON)
    case error(String)

    var description: String {
        switch self {
        case .ok(let value): "ok \(value)"
        case .error(let message): "error \(message)"
        }
    }
}

private struct ScriptError: Error, CustomStringConvertible {
    let description: String
}

/// Reads one step's arguments, with `@alias[.field]` already resolved.
private struct Arguments {
    let values: [String: ScriptJSON]

    init(_ value: ScriptJSON?) {
        if case .object(let members) = value { values = members } else { values = [:] }
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key]?.string else { throw ScriptError(description: "missing string \(key)") }
        return value
    }

    /// Absent or `null` → `nil`.
    func optionalString(_ key: String) -> String? {
        values[key]?.string
    }

    func optionalInt(_ key: String) -> Int? {
        values[key]?.int
    }

    func strings(_ key: String) -> [String]? {
        guard case .array(let entries) = values[key] else { return nil }
        return entries.compactMap(\.string)
    }

    /// Absent → `.unchanged`, `null` → `.clear`, a value → `.set` (JS `undefined` / `null` / value).
    func fieldUpdate(_ key: String) -> FieldUpdate<String> {
        switch values[key] {
        case nil: .unchanged
        case .null?: .clear
        case let value?: value.string.map(FieldUpdate.set) ?? .clear
        }
    }

    func photo(_ key: String) throws -> ItemPhotoInput? {
        guard let value = values[key], value != .null else { return nil }
        let photo = Arguments(value)
        return ItemPhotoInput(
            id: photo.optionalString("id"),
            uri: try photo.string("uri"),
            thumbUri: photo.optionalString("thumbUri"),
            width: photo.optionalInt("width"),
            height: photo.optionalInt("height"),
            byteSize: photo.optionalInt("byteSize")
        )
    }

    func photoUpdate(_ key: String) throws -> FieldUpdate<ItemPhotoInput> {
        switch values[key] {
        case nil: .unchanged
        case .null?: .clear
        default: try photo(key).map(FieldUpdate.set) ?? .clear
        }
    }

    func input(_ key: String = "input") -> Arguments {
        Arguments(values[key])
    }
}

@Suite("write parity with the TypeScript repositories")
struct WriteParityTests {
    /// Replaces `"@alias"` with that result's id and `"@alias.field"` with one of its fields.
    private static func resolve(_ value: ScriptJSON, _ aliases: [String: ScriptJSON]) throws -> ScriptJSON {
        switch value {
        case .string(let text) where text.hasPrefix("@"):
            let parts = text.dropFirst().split(separator: ".", maxSplits: 1).map(String.init)
            guard let result = aliases[parts[0]], let field = result[parts.count > 1 ? parts[1] : "id"] else {
                throw ScriptError(description: "unknown reference \(text)")
            }
            return field
        case .array(let entries):
            return .array(try entries.map { try resolve($0, aliases) })
        case .object(let members):
            return .object(try members.mapValues { try resolve($0, aliases) })
        default:
            return value
        }
    }

    private static func message(of error: any Error) -> String {
        switch error {
        case let error as InventoryError: error.message
        case let error as ConflictError: error.description
        case let error as DatabaseError: error.message ?? "\(error.resultCode)"
        default: "\(error)"
        }
    }

    /// Runs one step through the Swift repositories.
    private static func run(_ op: String, _ args: Arguments, _ repos: LocalRepositories) async throws -> ScriptJSON {
        switch op {
        case "sql":
            let sql = try args.string("sql")
            try await repos.store.queue.write { db in try db.execute(sql: sql) }
            return .null
        case "dump", "search":
            preconditionFailure("handled by the caller")
        case "spaces.create":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.spaces.create(CreateSpaceInput(
                name: try input.string("name"), icon: try input.string("icon"), color: try input.string("color")
            )))
        case "spaces.update":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.spaces.update(try args.string("id"), UpdateSpaceInput(
                name: input.optionalString("name"), icon: input.optionalString("icon"), color: input.optionalString("color")
            )))
        case "spaces.delete":
            return try ScriptJSON(encoding: try await repos.spaces.delete(try args.string("id")))
        case "containers.create":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.containers.create(CreateContainerInput(
                spaceId: try input.string("spaceId"),
                name: input.optionalString("name"),
                visualType: ContainerVisualType(rawValue: try input.string("visualType"))
            )))
        case "containers.update":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.containers.update(try args.string("id"), UpdateContainerInput(
                name: input.fieldUpdate("name"),
                visualType: input.optionalString("visualType").map(ContainerVisualType.init(rawValue:)),
                spaceId: input.optionalString("spaceId")
            )))
        case "containers.delete":
            return try ScriptJSON(encoding: try await repos.containers.delete(try args.string("id")))
        case "items.create":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.items.create(ItemDraft(
                containerId: try input.string("containerId"),
                name: input.optionalString("name"),
                category: input.optionalString("category"),
                quantity: input.optionalInt("quantity"),
                notes: input.optionalString("notes"),
                tags: input.strings("tags"),
                photo: try input.photo("photo")
            )))
        case "items.update":
            let input = args.input()
            return try ScriptJSON(encoding: try await repos.items.update(try args.string("id"), UpdateItemInput(
                containerId: input.optionalString("containerId"),
                name: input.optionalString("name"),
                category: input.fieldUpdate("category"),
                quantity: input.optionalInt("quantity"),
                notes: input.fieldUpdate("notes"),
                tags: input.strings("tags"),
                photo: try input.photoUpdate("photo"),
                expectedUpdatedAt: input.optionalInt("expectedUpdatedAt").map(Int64.init)
            )))
        case "items.delete":
            return try ScriptJSON(encoding: try await repos.items.delete(try args.string("id")))
        case "qr.bind":
            return try ScriptJSON(encoding: try await repos.qr.bind(
                token: try args.string("token"), containerId: try args.string("containerId")
            ))
        case "qr.createAndBind":
            return try ScriptJSON(encoding: try await repos.qr.createAndBind(try args.string("containerId")))
        case "qr.unbind":
            return .bool(try await repos.qr.unbind(try args.string("containerId")))
        default:
            throw ScriptError(description: "unknown op \(op)")
        }
    }

    /// Orphaned photo URIs come back in plan order, which SQL leaves unspecified (01 §7.1).
    private static func normalized(_ op: String, _ outcome: Outcome) -> Outcome {
        guard op.hasSuffix(".delete"), case .ok(.object(var members)) = outcome,
              case .array(let uris)? = members["orphanedPhotoUris"]
        else { return outcome }
        members["orphanedPhotoUris"] = .array(uris.sorted { ($0.string ?? "") < ($1.string ?? "") })
        return .ok(.object(members))
    }

    private static func compareTables(_ expected: [String: [[String: ScriptJSON]]], _ db: Database, step: Int) throws {
        #expect(try userTables(db).sorted() == expected.keys.sorted(), "step \(step): tables")
        for (table, rows) in expected {
            let actual = try dumpTable(db, table)
            let wanted = rows.map { $0.mapValues(\.scalar) }
            #expect(actual.count == wanted.count, "step \(step): \(table) row count")
            for (index, (got, want)) in zip(actual, wanted).enumerated() {
                #expect(got == want, "step \(step): \(table) row \(index)")
            }
        }
    }

    @Test("the fixture covers every write the repositories offer")
    func coversEveryWrite() throws {
        let script = try WriteScript.load()
        let ops = Set(script.steps.compactMap { $0["op"]?.string })
        #expect(ops.isSuperset(of: [
            "spaces.create", "spaces.update", "spaces.delete",
            "containers.create", "containers.update", "containers.delete",
            "items.create", "items.update", "items.delete",
            "qr.bind", "qr.createAndBind", "qr.unbind", "dump", "search",
        ]))
        // Both kinds of outcome are exercised.
        #expect(script.steps.contains { $0["error"] != nil })
        #expect(script.steps.filter { $0["ok"] != nil }.count > 40)
    }

    @Test("replays the script with the same results, errors and rows as the TypeScript repositories")
    func replaysScript() async throws {
        let script = try WriteScript.load()
        let repos = try script.makeRepositories()
        var aliases: [String: ScriptJSON] = [:]

        for (index, raw) in script.steps.enumerated() {
            let op = try #require(raw["op"]?.string)
            let step = try Self.resolve(raw, aliases)
            let args = Arguments(step)

            if op == "dump" {
                guard case .object(let expected)? = raw["ok"] else {
                    Issue.record("step \(index): dump without rows")
                    continue
                }
                let tables = expected.mapValues { value -> [[String: ScriptJSON]] in
                    guard case .array(let rows) = value else { return [] }
                    return rows.compactMap { row in
                        if case .object(let columns) = row { return columns }
                        return nil
                    }
                }
                try await repos.store.queue.read { db in try Self.compareTables(tables, db, step: index) }
                continue
            }

            let outcome: Outcome
            do {
                if op == "search" {
                    outcome = .ok(try ScriptJSON(encoding: try await repos.search.search(try args.string("query"))))
                } else {
                    outcome = .ok(try await Self.run(op, args, repos))
                }
            } catch let error as ScriptError {
                throw error
            } catch {
                outcome = .error(Self.message(of: error))
            }

            let expected: Outcome
            if let message = raw["error"]?.string {
                // node:sqlite errors reach the TS repositories' caller as `Error: <sqlite3_errmsg>`.
                expected = .error(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
            } else {
                expected = .ok(raw["ok"] ?? .null)
            }
            #expect(
                Self.normalized(op, outcome) == Self.normalized(op, expected),
                "step \(index) \(op) \(raw["as"]?.string ?? ""): \(outcome) vs \(expected)"
            )

            if let alias = raw["as"]?.string, case .ok(let value) = outcome, case .object = value {
                aliases[alias] = value
            }
        }

        try await repos.store.queue.read { db in try Self.compareTables(script.tables, db, step: script.steps.count) }
    }
}

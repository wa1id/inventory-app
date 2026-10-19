import Foundation
import InventoryCore
import Testing
@testable import InventoryNetwork

// Parity vectors from the real RN clients (Fixtures/generator/client-vectors.test.ts):
// householdRequest's parsing and error codes, listDevices' lenient entries,
// parseRecognitionResponse, parseBackupList, and the JS coercions they rely on.

private struct ClientVectors: Decodable {
    struct Outcome: Decodable {
        let kind: String
        let body: AnyJSON?
        let status: Int?
        let code: String?
        let updatedAt: Int64?
    }

    struct HouseholdCase: Decodable {
        let status: Int
        let body: String?
        let outcome: Outcome
    }

    struct DeviceCase: Decodable {
        let body: String
        let outcome: Outcome
    }

    struct RecognitionCase: Decodable {
        struct Result: Decodable {
            struct Suggestion: Decodable {
                let name: String?
                let category: String?
                let tags: [String]
                let confidence: Double
            }

            let status: String
            let reason: String?
            let contractVersion: Int?
            let suggestion: Suggestion?
        }

        let body: String
        let result: Result
    }

    struct BackupListCase: Decodable {
        let body: String
        let result: [BackupSummary]?
    }

    struct CoercionCase: Decodable {
        let json: String
        let string: String
        /// A number, null for NaN, or "Infinity" / "-Infinity".
        let number: AnyJSON
        let numberString: String?
    }

    struct URICase: Decodable {
        let value: String
        let encoded: String
    }

    let household: [HouseholdCase]
    let devices: [DeviceCase]
    let recognition: [RecognitionCase]
    let backupLists: [BackupListCase]
    let coercion: [CoercionCase]
    let uriComponents: [URICase]

    static func load() throws -> ClientVectors { try loadFixture("client-vectors") }
}

/// What a call came to, in the vectors' terms.
private enum Seen: Equatable {
    case ok(WireJSON)
    case http(Int, String)
    case conflict(Int64?)
}

private func seen<T>(_ work: () async throws -> T, map: (T) -> WireJSON) async -> Seen? {
    do {
        return .ok(map(try await work()))
    } catch let error as HouseholdHttpError {
        return .http(error.status, error.code)
    } catch let error as ConflictError {
        return .conflict(error.updatedAt)
    } catch {
        return nil
    }
}

private func expected(_ outcome: ClientVectors.Outcome) throws -> Seen {
    switch outcome.kind {
    case "ok":
        let data = try JSONEncoder().encode(try #require(outcome.body))
        return .ok(try #require(WireJSON.parse(data)))
    case "http":
        return .http(try #require(outcome.status), try #require(outcome.code))
    default:
        return .conflict(outcome.updatedAt)
    }
}

private func reply(status: Int, body: String?) -> StubReply {
    .response(status: status, headers: ["Content-Type": "application/json"], body: Data((body ?? "").utf8), delay: nil)
}

@Suite("RN client parity vectors")
struct ClientVectorTests {
    @Test("householdRequest: body parsing, error codes and conflict stamps match RN for every recorded answer")
    func householdRequest() async throws {
        for vector in try ClientVectors.load().household {
            let server = StubServer(reply: reply(status: vector.status, body: vector.body))
            let client = HouseholdClient(origin: "https://inventory.example", token: "t", transport: server.transport, telemetry: TelemetryRecorder().telemetry)
            let result = await seen({ try await client.object(HouseholdRequest(path: "/v1/x")) }, map: { $0.value })
            let want = try expected(vector.outcome)
            #expect(result == want, "status \(vector.status) body \(vector.body ?? "nil")")
        }
    }

    @Test("listDevices: unreadable entries are skipped and timestamps coerced as RN does")
    func devices() async throws {
        for vector in try ClientVectors.load().devices {
            let server = StubServer(reply: reply(status: 200, body: vector.body))
            let client = HouseholdClient(origin: "https://inventory.example", token: "t", transport: server.transport, telemetry: TelemetryRecorder().telemetry)
            let result = await seen({ try await client.listDevices() }) { devices in
                .array(devices.map { device in
                    .object([
                        "id": .string(device.id),
                        "name": .string(device.name),
                        "createdAt": .number(Double(device.createdAt)),
                        "lastSeenAt": device.lastSeenAt.map { .number(Double($0)) } ?? .null,
                    ])
                })
            }
            let want = try expected(vector.outcome)
            #expect(result == want, "body \(vector.body)")
        }
    }

    @Test("parseRecognitionResponse agrees with RN on every recorded body")
    func recognition() throws {
        for vector in try ClientVectors.load().recognition {
            let expected: RecognitionResult
            if vector.result.status == "success" {
                let suggestion = try #require(vector.result.suggestion)
                expected = .success(
                    RecognitionSuggestion(name: suggestion.name, category: suggestion.category, tags: suggestion.tags, confidence: suggestion.confidence),
                    contractVersion: try #require(vector.result.contractVersion)
                )
            } else {
                let reason = try #require(vector.result.reason)
                expected = .failed(try #require(RecognitionFailureReason(rawValue: reason)))
            }
            #expect(parseRecognitionResponse(Data(vector.body.utf8)) == expected, "body \(vector.body)")
        }
    }

    @Test("parseBackupList agrees with RN on every recorded body")
    func backupLists() throws {
        for vector in try ClientVectors.load().backupLists {
            #expect(parseBackupList(Data(vector.body.utf8)) == vector.result, "body \(vector.body)")
        }
    }

    @Test("String(), Number() and Number#toString agree with JS")
    func coercion() throws {
        for vector in try ClientVectors.load().coercion {
            let value = try #require(WireJSON.parse(Data(vector.json.utf8)), "\(vector.json)")
            #expect(value.jsString == vector.string, "String(\(vector.json))")
            let number = value.jsNumber
            switch vector.number {
            case .null: #expect(number == nil, "Number(\(vector.json))")
            case .number(let expected): #expect(number == expected, "Number(\(vector.json))")
            case .string("Infinity"): #expect(number == .infinity, "Number(\(vector.json))")
            case .string("-Infinity"): #expect(number == -.infinity, "Number(\(vector.json))")
            default: Issue.record("unexpected vector \(vector.json)")
            }
            if let numberString = vector.numberString, case .number(let raw) = value {
                #expect(WireJSON.jsNumberString(raw) == numberString, "(\(vector.json)).toString()")
            }
        }
    }

    @Test("encodeURIComponent agrees with JS")
    func uriComponents() throws {
        for vector in try ClientVectors.load().uriComponents {
            #expect(encodeURIComponent(vector.value) == vector.encoded, "\(vector.value)")
        }
    }
}

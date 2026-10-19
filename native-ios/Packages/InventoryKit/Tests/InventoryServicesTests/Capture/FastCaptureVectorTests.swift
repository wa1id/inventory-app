import Foundation
import InventoryCore
import InventoryNetwork
import Testing
@testable import InventoryServices

/// `Fixtures/capture/fast-capture.json`, generated from src/services/capture/fastCapture.ts and
/// fastReview.ts by `Fixtures/capture/generator/fast-capture-vectors.test.ts`.
private struct FastCaptureVectors: Decodable {
    struct Session: Decodable {
        struct Row: Decodable {
            let id: String
            let createdAt: Int64
        }

        let since: Int64
        let rows: [Row]
        let ids: [String]
    }

    struct Summary: Decodable {
        struct Counts: Decodable {
            let saved: Int
            let named: Int
            let unnamed: Int
            let pending: Int
        }

        let names: [String]
        let expected: Int
        let summary: Counts
    }

    struct Pipeline: Decodable {
        struct Outcome: Decodable {
            let status: String
            let itemId: String
            let name: String?
            let reason: String?
        }

        struct Update: Decodable {
            let name: String?
            let category: String?
            let tags: [String]
            let expectedUpdatedAt: Int64
            let hasName: Bool
        }

        struct Created: Decodable {
            struct Photo: Decodable {
                let uri: String
                let thumbUri: String
                let width: Int
                let height: Int
                let byteSize: Int?
            }

            let containerId: String
            let photo: Photo
            let hasName: Bool
        }

        let name: String?
        let category: String?
        let outcome: Outcome
        let updates: [Update]
        let created: [Created]
    }

    let sessions: [Session]
    let summaries: [Summary]
    let pipeline: [Pipeline]

    static func load() throws -> FastCaptureVectors {
        let url = try #require(Bundle.module.url(forResource: "fast-capture", withExtension: "json", subdirectory: "Fixtures/capture"))
        return try JSONDecoder().decode(FastCaptureVectors.self, from: Data(contentsOf: url))
    }
}

@Suite("Quick Snap parity vectors (fastCapture.ts, fastReview.ts)")
struct FastCaptureVectorTests {
    @Test("sessionItems keeps and orders the same rows as the TypeScript, ties included")
    func sessions() throws {
        let vectors = try FastCaptureVectors.load()
        #expect(vectors.sessions.count == 40)
        for session in vectors.sessions {
            let rows = session.rows.map { FastReviewRows.item(id: $0.id, createdAt: $0.createdAt) }
            #expect(FastReview.sessionItems(rows, since: session.since).map(\.id) == session.ids, "since \(session.since)")
        }
    }

    @Test("summarizeSession counts named rows with JS trim, as the TypeScript does")
    func summaries() throws {
        let vectors = try FastCaptureVectors.load()
        for vector in vectors.summaries {
            let rows = vector.names.enumerated().map { FastReviewRows.item(id: "r\($0.offset)", name: $0.element) }
            let expected = FastSessionSummary(
                saved: vector.summary.saved,
                named: vector.summary.named,
                unnamed: vector.summary.unnamed,
                pending: vector.summary.pending
            )
            #expect(FastReview.summarize(rows, expected: vector.expected) == expected, "\(vector.names.map { $0.unicodeScalars.map { String($0.value, radix: 16) } })")
        }
    }

    @Test("captureFastItem writes and answers what the TypeScript does for every suggested name")
    func pipeline() async throws {
        let vectors = try FastCaptureVectors.load()
        #expect(vectors.pipeline.count == 36)
        for vector in vectors.pipeline {
            let calls = FastCaptureCalls()
            let suggestion = RecognitionSuggestion(name: vector.name, category: vector.category, tags: ["dewalt"], confidence: 0.9)
            var dependencies = FastCaptureFakes.dependencies(calls) { _ in .success(suggestion, contractVersion: 1) }
            dependencies.storePhoto = { _, _ in
                StoredImage(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 646, height: 1400, byteSize: nil)
            }
            let base = dependencies.createItem
            dependencies.createItem = { draft in
                var item = try await base(draft)
                item.updatedAt = 5
                return item
            }

            let outcome = try await captureFastItem(containerId: DropZone.containerId, photo: FastCaptureFakes.photo, cropToAspect: nil, dependencies: dependencies)
            let label = "name \(vector.name.map { $0.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ") } ?? "null")"

            switch vector.outcome.status {
            case "recognized":
                let name = try #require(vector.outcome.name)
                #expect(outcome == .recognized(itemId: vector.outcome.itemId, name: name), "\(label)")
            default:
                let raw = try #require(vector.outcome.reason)
                let reason = try #require(RecognitionFailureReason(rawValue: raw))
                #expect(outcome == .unrecognized(itemId: vector.outcome.itemId, reason: reason), "\(label)")
            }

            #expect(calls.updated.count == vector.updates.count, "\(label)")
            for (update, expected) in zip(calls.updated.map(\.input), vector.updates) {
                #expect(update == UpdateItemInput(
                    name: expected.hasName ? expected.name : nil,
                    category: FieldUpdate(expected.category),
                    tags: expected.tags,
                    expectedUpdatedAt: expected.expectedUpdatedAt
                ), "\(label)")
            }

            let created = try #require(vector.created.first)
            let draft = try #require(calls.created.first)
            #expect(!created.hasName && draft.name == nil)
            #expect(draft.containerId == created.containerId)
            #expect(draft.photo == ItemPhotoInput(
                uri: created.photo.uri,
                thumbUri: created.photo.thumbUri,
                width: created.photo.width,
                height: created.photo.height,
                byteSize: created.photo.byteSize
            ))
        }
    }
}

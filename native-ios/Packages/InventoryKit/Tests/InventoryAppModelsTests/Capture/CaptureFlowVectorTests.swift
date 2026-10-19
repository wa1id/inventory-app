import Foundation
import InventoryCore
import InventoryServices
import Testing
@testable import InventoryAppModels

/// `Fixtures/capture/capture-flow.json`, generated from src/ui/capture/captureFlow.ts and
/// src/ui/scan/scanRules.ts by `Fixtures/capture/generator/capture-flow-vectors.test.ts`.
struct CaptureFlowVectors: Decodable {
    struct Fast: Decodable {
        let captured: Int
        let completed: Int
        let recognized: Int
        let text: String
        let settled: Bool
    }

    struct Leave: Decodable {
        let mode: String
        let captured: Int
        let result: String
    }

    struct Summary: Decodable {
        let saved: Int
        let named: Int
        let unnamed: Int
        let pending: Int

        var value: FastSessionSummary {
            FastSessionSummary(saved: saved, named: named, unnamed: unnamed, pending: pending)
        }
    }

    struct Review: Decodable {
        let summary: Summary
        let stalled: Bool
        let containerId: String
        let label: String?
        let status: String
        let statusText: String
        let title: String?
    }

    struct Toast: Decodable {
        struct Value: Decodable {
            let message: String
            let viewDropZone: Bool
        }

        let saved: Int
        let containerId: String
        let label: String?
        let toast: Value?
    }

    struct Expected: Decodable {
        let expected: Int
        let landed: Int
        let shown: Int
        let result: Int
    }

    struct Into: Decodable {
        let containerId: String
        let name: String?
        let code: String?
        let result: String
    }

    struct Label: Decodable {
        let name: String?
        let result: String
    }

    struct Token: Decodable {
        let value: String
        let result: String
    }

    struct Plan: Decodable {
        struct Value: Decodable {
            struct Confirm: Decodable {
                let title: String
                let body: String
                let confirmLabel: String
            }

            let write: Bool
            let confirm: Confirm?
        }

        let existing: String?
        let label: String
        let plan: Value
    }

    struct Failure: Decodable {
        let status: Int
        let code: String
        let message: String
    }

    let fast: [Fast]
    let leave: [Leave]
    let review: [Review]
    let toasts: [Toast]
    let expected: [Expected]
    let into: [Into]
    let labels: [Label]
    let tokens: [Token]
    let plans: [Plan]
    let failures: [Failure]
    let local: String

    static func load() throws -> CaptureFlowVectors {
        let url = try #require(Bundle.module.url(forResource: "capture-flow", withExtension: "json", subdirectory: "Fixtures/capture"))
        return try JSONDecoder().decode(CaptureFlowVectors.self, from: Data(contentsOf: url))
    }
}

@Suite("CaptureFlow parity vectors (captureFlow.ts)")
struct CaptureFlowVectorTests {
    @Test("fastStatus says the same over every tally")
    func fastStatus() throws {
        let vectors = try CaptureFlowVectors.load()
        #expect(vectors.fast.count == 35)
        for vector in vectors.fast {
            let tallies = FastTallies(captured: vector.captured, completed: vector.completed, recognized: vector.recognized)
            #expect(CaptureFlow.fastStatus(tallies) == FastStatus(text: vector.text, settled: vector.settled), "\(tallies)")
        }
    }

    @Test("leaveCamera goes where the TypeScript goes")
    func leaveCamera() throws {
        for vector in try CaptureFlowVectors.load().leave {
            let mode = try #require(CaptureMode(rawValue: vector.mode))
            #expect(CaptureFlow.leaveCamera(mode: mode, captured: vector.captured).rawValue == vector.result)
        }
    }

    @Test("reviewStatus, reviewStatusText and reviewTitle agree over the whole grid")
    func review() throws {
        let vectors = try CaptureFlowVectors.load()
        #expect(vectors.review.count == 480)
        for vector in vectors.review {
            let summary = vector.summary.value
            let status = CaptureFlow.reviewStatus(summary, stalled: vector.stalled)
            #expect(status.rawValue == vector.status, "\(summary) stalled \(vector.stalled)")
            #expect(CaptureFlow.reviewStatusText(status, summary) == vector.statusText, "\(summary)")
            #expect(CaptureFlow.reviewTitle(summary, status: status, containerId: vector.containerId, label: vector.label) == vector.title, "\(summary) \(vector.containerId) \(vector.label ?? "nil")")
        }
    }

    @Test("reviewDoneToast agrees, plurals included")
    func toasts() throws {
        for vector in try CaptureFlowVectors.load().toasts {
            let toast = CaptureFlow.reviewDoneToast(saved: vector.saved, containerId: vector.containerId, label: vector.label)
            #expect(toast == vector.toast.map { QuickSnapDoneToast(message: $0.message, viewDropZone: $0.viewDropZone) }, "\(vector.saved) \(vector.containerId)")
        }
    }

    @Test("expectedStillShown agrees over the grid")
    func expectedStillShown() throws {
        for vector in try CaptureFlowVectors.load().expected {
            #expect(CaptureFlow.expectedStillShown(expected: vector.expected, landed: vector.landed, shown: vector.shown) == vector.result)
        }
    }

    @Test("intoA11y spells the same codes and treats names the same way")
    func into() throws {
        for vector in try CaptureFlowVectors.load().into {
            let place = vector.code.map {
                CaptureIntoPlace(containerId: vector.containerId, containerName: vector.name, containerShortCode: $0, spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF")
            }
            #expect(CaptureFlow.intoA11y(containerId: vector.containerId, place: place) == vector.result, "\(vector.name ?? "nil") \(vector.code ?? "nil")")
        }
    }
}

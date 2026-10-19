import InventoryCore
import Testing
@testable import InventoryAppModels

@Suite("ScanRules parity vectors (scanRules.ts)")
struct ScanRulesVectorTests {
    @Test("labelFor trims names as JS does")
    func labels() throws {
        for vector in try CaptureFlowVectors.load().labels {
            #expect(ScanRules.labelFor(name: vector.name, shortCode: "BOX-7K2M") == vector.result, "\(vector.name.map { $0.unicodeScalars.map { String($0.value, radix: 16) } } ?? [])")
        }
    }

    @Test("tokenParam trims as JS does")
    func tokens() throws {
        for vector in try CaptureFlowVectors.load().tokens {
            #expect(ScanRules.tokenParam(vector.value) == vector.result)
        }
    }

    @Test("planBind compares tokens with JS lowercasing and asks the same question")
    func plans() throws {
        for vector in try CaptureFlowVectors.load().plans {
            let plan = ScanRules.planBind(existingToken: vector.existing, token: String(repeating: "a", count: 32), label: vector.label)
            #expect(plan.write == vector.plan.write)
            #expect(plan.confirm == vector.plan.confirm.map { ConfirmOptions(title: $0.title, body: $0.body, confirmLabel: $0.confirmLabel) })
        }
    }

    @Test("linkFailureMessage reads every household failure the same way")
    func failures() throws {
        let vectors = try CaptureFlowVectors.load()
        for vector in vectors.failures {
            #expect(ScanRules.linkFailureMessage(HouseholdHttpError(status: vector.status, code: vector.code)) == vector.message, "\(vector.status) \(vector.code)")
        }
        struct Local: Error {}
        #expect(ScanRules.linkFailureMessage(Local()) == vectors.local)
    }
}

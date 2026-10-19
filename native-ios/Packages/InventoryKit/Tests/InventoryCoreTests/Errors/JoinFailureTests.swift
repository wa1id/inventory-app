import Testing
@testable import InventoryCore

// Port of the joinFailure block of src/ui/household/__tests__/join.test.ts:66-81.
// Fixtures/errors.json checks it against the real join.ts for every cause.

/// RN `new Error(message)`.
private struct PlainError: Error {
    let message: String
}

private func http(_ status: Int, _ code: String) -> HouseholdHttpError {
    HouseholdHttpError(status: status, code: code)
}

@Suite("joinFailure")
struct JoinFailureTests {
    @Test("reads a 401 from pairing as a refused code")
    func readsA401FromPairingAsARefusedCode() {
        #expect(joinFailure(http(401, "unauthorized")) == .refused)
    }

    @Test("reads no answer, a timeout and Cloudflare’s origin errors as offline")
    func readsNoAnswerATimeoutAndCloudflaresOriginErrorsAsOffline() {
        #expect(joinFailure(http(0, "offline")) == .offline)
        #expect(joinFailure(http(0, "timeout")) == .offline)
        #expect(joinFailure(http(530, "http_530")) == .offline)
    }

    @Test("reads anything else as a plain failure")
    func readsAnythingElseAsAPlainFailure() {
        #expect(joinFailure(http(500, "invalid_response")) == .other)
        #expect(joinFailure(PlainError(message: "boom")) == .other)
    }

    // join.ts:73-81, rule by rule.
    @Test("a refused code wins over an unreachable answer; 401 or unauthorized alone is enough")
    func refusedWinsOverUnreachable() {
        #expect(joinFailure(http(520, "unauthorized")) == .refused)
        #expect(joinFailure(http(401, "timeout")) == .refused)
        #expect(joinFailure(http(403, "unauthorized")) == .refused)
        #expect(joinFailure(http(401, "refused")) == .refused)
        #expect(joinFailure(http(403, "Unauthorized")) == .other)
    }

    @Test("gone, conflicts and a nil cause are plain failures")
    func everythingElseIsOther() {
        #expect(joinFailure(http(404, "not_found")) == .other)
        #expect(joinFailure(ConflictError(updatedAt: 1)) == .other)
        #expect(joinFailure(nil) == .other)
    }

    @Test("the raw value is the household_join_failed outcome")
    func rawValues() {
        #expect(JoinFailure.allCases.map(\.rawValue) == ["refused", "offline", "other"])
    }
}

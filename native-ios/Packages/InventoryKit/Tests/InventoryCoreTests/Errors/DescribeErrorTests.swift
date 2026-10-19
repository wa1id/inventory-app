import Foundation
import Testing
@testable import InventoryCore

// Port of src/ui/__tests__/errors.test.ts, plus the 09 §10.2 rules the RN tests
// leave implicit and Fixtures/errors.json (every cause × context × subject, run
// through the real errors.ts, and joinFailure from src/ui/household/join.ts).

/// RN `RAW`: `/http_|invalid_|offline|timeout|unauthorized|not_found|photo_missing/`.
private let rawCodeFragments = ["http_", "invalid_", "offline", "timeout", "unauthorized", "not_found", "photo_missing"]

private func showsRawCode(_ text: String) -> Bool {
    rawCodeFragments.contains { text.contains($0) }
}

/// RN `new Error(message)`: an error that is neither a household answer nor a conflict.
private struct PlainError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}

/// Stands in for JS `undefined`, a cause that carries nothing: Swift has no such
/// value, and every thrown Swift error that is not classified reads as local.
private struct NoInformation: Error {}

private func http(_ status: Int, _ code: String) -> HouseholdHttpError {
    HouseholdHttpError(status: status, code: code)
}

@Suite("describeError")
struct DescribeErrorTests {
    @Test("treats these as the home server not answering", arguments: [
        http(0, "offline"),
        http(0, "timeout"),
        http(502, "http_502"),
        http(530, "http_530"),
        http(520, "origin_down"),
    ])
    func treatsAsTheHomeServerNotAnswering(cause: HouseholdHttpError) {
        let read = describeError(cause, context: .read)
        #expect(read.kind == .offline)
        #expect(read.title == "The home server did not answer")
        #expect(read.body.contains("Nothing on this phone was lost"))
        #expect(describeError(cause, context: .save).body.contains("What you typed is still here"))
    }

    @Test("treats a 401 as a removed phone, except while joining")
    func treatsA401AsARemovedPhoneExceptWhileJoining() {
        #expect(describeError(http(401, "unauthorized")).kind == .revoked)
        #expect(describeError(http(403, "unauthorized")).kind == .revoked)
        #expect(describeError(http(401, "unauthorized"), context: .join).kind == .server)
    }

    @Test("treats null, 404 and not_found as gone, named by subject")
    func treatsNull404AndNotFoundAsGone() {
        #expect(describeError(nil, context: .read, subject: .item).title == "This item is gone")
        #expect(
            describeError(http(404, "http_404"), context: .read, subject: .space).title
                == "This space is not in the household any more"
        )
        let container = describeError(http(400, "not_found"), context: .read, subject: .container)
        #expect(container.kind == .gone)
        #expect(container.title == "This container is not in the household any more")
    }

    @Test("separates a missing photo from a missing item")
    func separatesAMissingPhotoFromAMissingItem() {
        #expect(describeError(http(0, "photo_missing")).kind == .photo)
    }

    @Test("reads these as a home-server problem", arguments: [
        "http_500", "invalid_json", "invalid_response", "photos_not_configured",
    ])
    func readsAsAHomeServerProblem(code: String) {
        #expect(describeError(http(500, code)).kind == .server)
    }

    @Test("reads a conflict as a change on another phone")
    func readsAConflictAsAChangeOnAnotherPhone() {
        #expect(describeError(ConflictError(updatedAt: 1)).kind == .conflict)
    }

    @Test("reads anything else as the local database")
    func readsAnythingElseAsTheLocalDatabase() {
        let read = describeError(PlainError(message: "SQLITE_BUSY"), context: .read)
        #expect(read.kind == .local)
        #expect(read.body == "Try again. If this keeps happening, restart the app. Your data is still on this phone.")
        #expect(describeError(PlainError(message: "SQLITE_BUSY"), context: .save).body == "It was not saved. Try again.")
    }

    @Test("never puts a raw code or message on screen")
    func neverPutsARawCodeOrMessageOnScreen() {
        let causes: [(any Error)?] = [
            http(0, "offline"),
            http(0, "timeout"),
            http(530, "http_530"),
            http(500, "invalid_json"),
            http(500, "invalid_response"),
            http(401, "unauthorized"),
            http(404, "not_found"),
            http(0, "photo_missing"),
            ConflictError(),
            PlainError(message: "http_500 invalid_json"),
            nil,
            NoInformation(),
        ]
        for cause in causes {
            for context in ErrorContext.allCases {
                let copy = describeError(cause, context: context)
                #expect(!showsRawCode(copy.title), "\(String(describing: cause)) \(context)")
                #expect(!showsRawCode(copy.body), "\(String(describing: cause)) \(context)")
            }
        }
    }
}

@Suite("needsRefreshBanner and isOffline")
struct NeedsRefreshBannerAndIsOfflineTests {
    let offline = http(0, "offline")
    let removed = http(401, "unauthorized")
    let server = http(500, "http_500")

    @Test("leaves offline and removed phones to their own banner and layer")
    func leavesOfflineAndRemovedPhonesToTheirOwnBannerAndLayer() {
        #expect(!needsRefreshBanner(true, cause: offline))
        #expect(!needsRefreshBanner(true, cause: removed))
    }

    @Test("explains any other failed refresh, and nothing when the refresh worked")
    func explainsAnyOtherFailedRefresh() {
        #expect(needsRefreshBanner(true, cause: server))
        #expect(needsRefreshBanner(true, cause: PlainError(message: "disk I/O error")))
        #expect(!needsRefreshBanner(false, cause: server))
    }

    @Test("tells a connection failure from any other")
    func tellsAConnectionFailureFromAnyOther() {
        #expect(isOffline(offline))
        #expect(isOffline(http(530, "http_530")))
        #expect(!isOffline(server))
        #expect(!isOffline(PlainError(message: "constraint failed")))
    }
}

// 09 §10.2, rule by rule.
@Suite("describeError rules")
struct DescribeErrorRuleTests {
    @Test("defaults to reading a list")
    func defaultsToReadingAList() {
        #expect(describeError(nil) == describeError(nil, context: .read, subject: .list))
        #expect(describeError(nil).title == "This item is gone")
        #expect(describeError(PlainError(message: "x")).body == describeError(PlainError(message: "x"), context: .read).body)
    }

    @Test("reads and joins get the reading words; every other context the saving words")
    func readingVersusSavingWords() {
        for context in ErrorContext.allCases {
            let reading = context == .read || context == .join
            #expect(describeError(http(0, "offline"), context: context).body
                == (reading ? "Check the internet connection, then try again. Nothing on this phone was lost."
                    : "It was not saved. Check the internet connection and try again. What you typed is still here."))
            #expect(describeError(PlainError(message: "x"), context: context).body
                == (reading ? "Try again. If this keeps happening, restart the app. Your data is still on this phone."
                    : "It was not saved. Try again."))
        }
    }

    @Test("a gone record is named by subject; a list reads as an item")
    func goneTitlesBySubject() {
        let titles = ErrorSubject.allCases.map { describeError(nil, subject: $0).title }
        #expect(titles == [
            "This item is gone",
            "This space is not in the household any more",
            "This container is not in the household any more",
            "This item is gone",
        ])
        #expect(describeError(nil).body == "It was deleted, probably on another phone. Nothing else changed.")
    }

    @Test("an unreachable home server wins over every other household rule")
    func unreachableWinsOverEverything() {
        #expect(describeError(http(401, "timeout")).kind == .offline)
        #expect(describeError(http(404, "offline")).kind == .offline)
        #expect(describeError(http(0, "http_525"), context: .join).kind == .offline)
        #expect(describeError(http(530, "photo_missing")).kind == .offline)
    }

    @Test("an http_NNN code's status wins over the response status, for reachability only")
    func codeStatusWinsForReachabilityOnly() {
        #expect(describeError(http(200, "http_525")).kind == .offline)
        #expect(describeError(http(525, "http_500")).kind == .server)
        // Gone and revoked look at the response status and the code itself, never at the code's digits.
        #expect(describeError(http(502, "http_404")).kind == .server)
        #expect(describeError(http(404, "http_500")).kind == .gone)
        #expect(describeError(http(500, "http_401")).kind == .server)
    }

    @Test("only http_ and three ASCII digits count as a status code")
    func onlyThreeASCIIDigitsCount() {
        #expect(httpStatus(inCode: "http_502") == 502)
        #expect(httpStatus(inCode: "http_000") == 0)
        for code in ["http_5020", "http_50", "HTTP_502", "http_502 ", " http_502", "http_502\n", "http_５０２", "http_٥٠٢", "http_-50"] {
            #expect(httpStatus(inCode: code) == nil, "\(scalarDump(code))")
        }
        // Cloudflare's 520–530 band, bounds included, and 502 by status alone.
        #expect(describeError(http(520, "origin_down")).kind == .offline)
        #expect(describeError(http(530, "x")).kind == .offline)
        #expect(describeError(http(519, "x")).kind == .server)
        #expect(describeError(http(531, "x")).kind == .server)
        #expect(describeError(http(502, "x")).kind == .offline)
        #expect(describeError(http(503, "x")).kind == .server)
    }

    @Test("codes match exactly, as JS ===")
    func codesMatchExactly() {
        #expect(describeError(http(0, "Offline")).kind == .server)
        #expect(describeError(http(403, "Unauthorized")).kind == .server)
        #expect(describeError(http(400, "not found")).kind == .server)
        #expect(describeError(http(0, "photo_missing ")).kind == .server)
    }

    @Test("a 404 while joining is still gone; a refused code is a server problem")
    func joiningRules() {
        #expect(describeError(http(404, "not_found"), context: .join).kind == .gone)
        #expect(describeError(http(403, "unauthorized"), context: .join).kind == .server)
    }

    @Test("a conflict reads the same whatever the context or subject")
    func conflictIsContextFree() {
        for context in ErrorContext.allCases {
            for subject in ErrorSubject.allCases {
                let copy = describeError(ConflictError(updatedAt: nil), context: context, subject: subject)
                #expect(copy == ErrorCopy(
                    kind: .conflict,
                    title: "This was changed on another phone",
                    body: "Someone changed it on another phone just now, so nothing was overwritten. Try again to see the latest version."
                ))
            }
        }
    }

    @Test("an error's own message never matters")
    func messageNeverMatters() {
        let liar = PlainError(message: "HouseholdHttpError offline 401 unauthorized")
        #expect(describeError(liar).kind == .local)
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                         userInfo: [NSLocalizedDescriptionKey: "offline timeout"])
        #expect(describeError(ns).kind == .local)
        #expect(!showsRawCode(describeError(ns).body))
    }

    @Test("the kind's raw value is the RN kind string")
    func kindRawValues() {
        #expect(ErrorKind.allCases.map(\.rawValue) == ["offline", "revoked", "conflict", "gone", "photo", "server", "local"])
        #expect(ErrorContext.allCases.map(\.rawValue) == ["read", "save", "move", "quantity", "delete", "label", "join"])
        #expect(ErrorSubject.allCases.map(\.rawValue) == ["item", "space", "container", "list"])
    }
}

@Suite("errorClass")
struct ErrorClassTests {
    @Test("names the error's type, as RN's error.name did for its own classes")
    func namesTheType() {
        #expect(errorClass(of: http(0, "offline")) == "HouseholdHttpError")
        #expect(errorClass(of: ConflictError()) == "ConflictError")
        #expect(errorClass(of: CancellationError()) == "CancellationError")
    }

    @Test("never carries the error's message")
    func neverCarriesTheMessage() {
        let secret = PlainError(message: "Cordless drill in /var/mobile/Documents/item-photos/a.webp")
        #expect(errorClass(of: secret) == "PlainError")
        let ns = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cordless drill"])
        #expect(!errorClass(of: ns).contains("Cordless"))
    }
}

@Suite("describeError parity (Fixtures/errors.json)")
struct DescribeErrorParityTests {
    struct Cause: Decodable {
        let type: String
        let status: Int?
        let code: String?
        let updatedAt: Int64?
        let message: String?

        var error: (any Error)? {
            switch type {
            case "http": HouseholdHttpError(status: status ?? 0, code: code ?? "")
            case "conflict": ConflictError(updatedAt: updatedAt)
            case "null": nil
            case "error": PlainError(message: message ?? "")
            default: NoInformation()  // "undefined"
            }
        }
    }

    /// `[kind, title index, body index]`.
    struct Described: Decodable {
        let kind: String
        let title: Int
        let body: Int

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            kind = try container.decode(String.self)
            title = try container.decode(Int.self)
            body = try container.decode(Int.self)
        }
    }

    struct Entry: Decodable {
        let cause: Cause
        let described: [[Described]]
        let defaults: String
        let refreshBanner: Bool
        let offline: Bool
        /// RN `joinFailure(cause)` (src/ui/household/join.ts).
        let join: String
    }

    struct File: Decodable {
        let contexts: [String]
        let subjects: [String]
        let texts: [String]
        let entries: [Entry]
    }

    @Test("every cause, context and subject reads as errors.ts reads it")
    func matchesTypeScript() throws {
        let file = try loadFixture("errors", as: File.self)
        let contexts = try file.contexts.map { try #require(ErrorContext(rawValue: $0)) }
        let subjects = try file.subjects.map { try #require(ErrorSubject(rawValue: $0)) }
        #expect(file.entries.count > 500)
        for entry in file.entries {
            let cause = entry.cause.error
            let label = "\(entry.cause.type) \(entry.cause.status.map(String.init) ?? "") \(scalarDump(entry.cause.code ?? ""))"
            for (contextIndex, context) in contexts.enumerated() {
                for (subjectIndex, subject) in subjects.enumerated() {
                    let expected = entry.described[contextIndex][subjectIndex]
                    let actual = describeError(cause, context: context, subject: subject)
                    #expect(actual.kind.rawValue == expected.kind, "\(label) \(context) \(subject)")
                    #expect(actual.title == file.texts[expected.title], "\(label) \(context) \(subject)")
                    #expect(actual.body == file.texts[expected.body], "\(label) \(context) \(subject)")
                }
            }
            #expect(describeError(cause).kind.rawValue == entry.defaults, "\(label)")
            #expect(needsRefreshBanner(true, cause: cause) == entry.refreshBanner, "\(label)")
            #expect(!needsRefreshBanner(false, cause: cause), "\(label)")
            #expect(isOffline(cause) == entry.offline, "\(label)")
            #expect(joinFailure(cause).rawValue == entry.join, "\(label)")
        }
        // Every kind and every join outcome is reached at least once.
        let kinds = Set(file.entries.flatMap { $0.described.flatMap { $0.map(\.kind) } })
        #expect(kinds == Set(ErrorKind.allCases.map(\.rawValue)))
        #expect(Set(file.entries.map(\.join)) == Set(JoinFailure.allCases.map(\.rawValue)))
    }

    @Test("no errors.* copy shows a raw code")
    func noCopyShowsARawCode() throws {
        let file = try loadFixture("errors", as: File.self)
        for text in file.texts {
            #expect(!showsRawCode(text), "\(text)")
        }
    }
}

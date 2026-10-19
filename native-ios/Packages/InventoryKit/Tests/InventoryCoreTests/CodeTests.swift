import Foundation
import Testing
@testable import InventoryCore

// Port of src/ui/__tests__/code.test.ts and the codeProblem and serverHost tests
// of src/ui/household/__tests__/join.test.ts, plus Fixtures/codes.json and the
// code columns of Fixtures/folding.json.

@Suite("normaliseCode")
struct NormaliseCodeTests {
    @Test("drops spaces and hyphens and upper-cases")
    func dropsSpacesAndHyphensAndUpperCases() {
        #expect(normaliseCode(" mmwky-m2h78 ") == "MMWKYM2H78")
        #expect(normaliseCode("mmwky\nm2h78\t") == "MMWKYM2H78")
    }

    @Test("folds the look-alikes the way the server decodes them")
    func foldsTheLookAlikes() {
        #expect(normaliseCode("il0o") == "1100")
        #expect(normaliseCode("ILO") == "110")
    }
}

@Suite("invalidCodeChars")
struct InvalidCodeCharsTests {
    @Test("reports characters Crockford base32 never uses, once each")
    func reportsInvalidCharactersOnceEach() {
        #expect(invalidCodeChars("U") == ["U"])
        #expect(invalidCodeChars("ABUU!") == ["U", "!"])
        #expect(invalidCodeChars(normaliseCode("MMWKY-M2H78")) == [])
    }
}

@Suite("formatCode")
struct FormatCodeTests {
    @Test("groups in fives")
    func groupsInFives() {
        #expect(formatCode("") == "")
        #expect(formatCode("MMWKY") == "MMWKY")
        #expect(formatCode("MMWKYM2H78A") == "MMWKY-M2H78-A")
    }
}

// Port of the codeProblem block of src/ui/household/__tests__/join.test.ts (03 §3.5, §14.5).
@Suite("codeProblem")
struct CodeProblemTests {
    static let code = "MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S"

    @Test("accepts a full code however it was typed")
    func acceptsAFullCodeHoweverItWasTyped() {
        #expect(codeProblem(normaliseCode(Self.code)) == nil)
        #expect(codeProblem(normaliseCode(Self.code.lowercased().replacingOccurrences(of: "-", with: " "))) == nil)
    }

    @Test("names characters no code uses before complaining about the length")
    func namesCharactersBeforeLength() {
        #expect(codeProblem(normaliseCode("MMWKU-M2H7%")) == .chars("U %"))
    }

    @Test("reports the length of a short or long code")
    func reportsTheLength() {
        #expect(codeProblem(normaliseCode("MMWKY-M2H78-ABCDE-FGH")) == .length(count: 18))
        #expect(codeProblem(normaliseCode("\(Self.code)X")) == .length(count: 27))
    }

    @Test("the code length is 26")
    func codeLengthIs26() {
        #expect(codeLength == 26)
        #expect(codeLength == RecoveryCode.length)
    }
}

@Suite("serverHost")
struct ServerHostTests {
    @Test("keeps only the host of the address")
    func keepsOnlyTheHost() {
        #expect(serverHost("https://inventory.wystudio.be") == "inventory.wystudio.be")
        #expect(serverHost("http://192.168.1.5:8788/") == "192.168.1.5:8788")
        #expect(serverHost("inventory.example") == "inventory.example")
    }

    @Test("falls back to the untrimmed input when nothing is left")
    func fallsBackToTheInput() {
        #expect(serverHost("   ") == "   ")
        #expect(serverHost("/path") == "/path")
        #expect(serverHost("http://") == "http://")
    }
}

@Suite("code parity (Fixtures/codes.json, folding.json)")
struct CodeParityTests {
    struct Problem: Decodable { let kind: String; let chars: String?; let count: Int? }
    struct CodeEntry: Decodable {
        let input: String
        let normalised: String
        let invalid: [String]
        let formatted: String
        let problem: Problem?
    }
    struct HostEntry: Decodable { let input: String; let host: String }
    struct File: Decodable { let codes: [CodeEntry]; let hosts: [HostEntry] }

    @Test("normaliseCode, invalidCodeChars and formatCode match JS")
    func codesMatchJS() throws {
        for entry in try loadFixture("codes", as: File.self).codes {
            let normalised = normaliseCode(entry.input)
            #expect(sameScalars(normalised, entry.normalised), "\(scalarDump(entry.input))")
            #expect(sameScalars(invalidCodeChars(normalised), entry.invalid), "\(scalarDump(entry.input))")
            #expect(sameScalars(formatCode(normalised), entry.formatted), "\(scalarDump(entry.input))")
            let expected: CodeProblem? = switch entry.problem?.kind {
            case "chars": .chars(entry.problem?.chars ?? "")
            case "length": .length(count: entry.problem?.count ?? -1)
            default: nil
            }
            #expect(codeProblem(normalised) == expected, "\(scalarDump(entry.input))")
        }
    }

    @Test("serverHost matches JS")
    func hostsMatchJS() throws {
        for entry in try loadFixture("codes", as: File.self).hosts {
            #expect(sameScalars(serverHost(entry.input), entry.host), "\(scalarDump(entry.input))")
        }
    }

    @Test("normaliseCode and invalidCodeChars match JS over the corpus")
    func corpusMatchesJS() throws {
        let entries: [FoldingEntry] = try loadFixture("folding")
        for entry in entries {
            let normalised = normaliseCode(entry.input)
            #expect(sameScalars(normalised, entry.normaliseCode), "\(scalarDump(entry.input))")
            #expect(sameScalars(invalidCodeChars(normalised), entry.invalidCodeChars), "\(scalarDump(entry.input))")
        }
    }
}

import Foundation
import Testing
@testable import InventoryCore

// Ports the pure parts of src/services/account/__tests__/identity.test.ts
// (the keychain lifecycle tests belong to the account store), all of
// worker/test/base32.test.ts, the subtle cases of 03-sync-account.md §14.2, the
// §3.8 vector table and Fixtures/base32.json.

private func fill(_ byte: UInt8, _ count: Int = RecoveryCode.secretByteCount) -> [UInt8] {
    Array(repeating: byte, count: count)
}

@Suite("cross-implementation vectors")
struct CrossImplementationVectorTests {
    let secret = fill(0x42)

    @Test("encodes a known secret to the code the service expects")
    func encodesAKnownSecret() {
        #expect(CrockfordBase32.encode(secret) == "89144GJ289144GJ289144GJ288")
    }

    @Test("derives the account id the service derives")
    func derivesTheAccountId() {
        #expect(deriveAccountId(secret) == "900dfeb7f1b5e344209e2abce56c333d")
    }

    // 03 §3.8.
    static let table: [(UInt8?, String, String, String)] = [
        (0x42, "89144GJ289144GJ289144GJ288", "89144-GJ289-144GJ-28914-4GJ28-8", "900dfeb7f1b5e344209e2abce56c333d"),
        (0x00, "00000000000000000000000000", "00000-00000-00000-00000-00000-0", "374708fff7719dd5979ec875d56cd228"),
        (0xFF, "ZZZZZZZZZZZZZZZZZZZZZZZZZW", "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-W", "5ac6a5945f16500911219129984ba8b3"),
        (nil, "041061050R3GG28A1C60T3GF20", "04106-1050R-3GG28-A1C60-T3GF2-0", "5dfbabeedf318bf33c0927c43d7630f5"),
        (0x11, "248H248H248H248H248H248H24", "248H2-48H24-8H248-H248H-248H2-4", "b8f12ea8c9a95d4b4641b03d9fa5a71a"),
    ]

    @Test("03 §3.8 vector table", arguments: table)
    func vectorTable(fillByte: UInt8?, code: String, formatted: String, accountId: String) {
        let secret = fillByte.map { fill($0) } ?? Array(1...16)
        #expect(CrockfordBase32.encode(secret) == code)
        #expect(RecoveryCode.format(code) == formatted)
        #expect(deriveAccountId(secret) == accountId)
        #expect(CrockfordBase32.decode(formatted) == secret)
    }
}

@Suite("recovery code encoding")
struct RecoveryCodeEncodingTests {
    @Test("round-trips random secrets")
    func roundTripsRandomSecrets() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let secret = (0..<RecoveryCode.secretByteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            #expect(CrockfordBase32.decode(CrockfordBase32.encode(secret)).map { Array($0.prefix(16)) } == secret)
        }
    }

    @Test("survives the transcription mistakes it was chosen to survive")
    func survivesTranscriptionMistakes() {
        let secret = fill(0x11)
        let code = CrockfordBase32.encode(secret)
        // Lowercase, hyphenated, and with 1 and 0 written as the letters people reach for instead.
        let retyped = RecoveryCode.format(code).lowercased()
            .replacingOccurrences(of: "1", with: "l")
            .replacingOccurrences(of: "0", with: "o")
        #expect(CrockfordBase32.decode(retyped).map { Array($0.prefix(16)) } == secret)
    }

    // The pure half of identity.test.ts "adopts an account from a code typed in any reasonable shape".
    @Test("canonicalises a code typed in any reasonable shape")
    func canonicalisesTypedCodes() {
        let code = CrockfordBase32.encode(fill(0x42))
        #expect(RecoveryCode.canonical(RecoveryCode.format(code).lowercased()) == code)
        #expect(RecoveryCode.canonical(String(code.dropLast()) + "B") == code)
        #expect(RecoveryCode.secret(from: code) == fill(0x42))
    }

    // The pure half of identity.test.ts "refuses a code that decodes to too few bytes" / "…outside the alphabet".
    @Test("refuses short codes and characters outside the alphabet")
    func refusesMalformedCodes() {
        #expect(RecoveryCode.secret(from: "89144") == nil)
        #expect(RecoveryCode.secret(from: String(repeating: "U", count: 26)) == nil)
        #expect(RecoveryCode.secret(from: "89144GJ289144GJ289144GJ28800") == nil)  // 28 characters → 17 bytes
        #expect(RecoveryCode.canonical("") == nil)
    }
}

@Suite("worker base32")
struct WorkerBase32Tests {
    @Test("round-trips every byte value")
    func roundTripsEveryByteValue() {
        for seed in 0...255 {
            let bytes = fill(UInt8(seed))
            #expect(CrockfordBase32.decode(CrockfordBase32.encode(bytes)).map { Array($0.prefix(16)) } == bytes)
        }
    }

    @Test("a 16-byte secret encodes to a code of the documented length")
    func encodesToTheDocumentedLength() {
        #expect(CrockfordBase32.encode(fill(0xFF)).count == RecoveryCode.length)
    }

    @Test("folds the characters people actually mistype")
    func foldsMistypedCharacters() {
        let canonical = CrockfordBase32.decode("10101010101010101010101010")
        #expect(canonical != nil)
        #expect(CrockfordBase32.decode("IOIOIOIOIOIOIOIOIOIOIOIOIO") == canonical)
        #expect(CrockfordBase32.decode("LOLOLOLOLOLOLOLOLOLOLOLOLO") == canonical)
    }

    @Test("ignores case, hyphens, and surrounding whitespace")
    func ignoresCaseHyphensAndWhitespace() {
        let bytes: [UInt8] = Array(1...16)
        let code = CrockfordBase32.encode(bytes)
        let messy = "  \(RecoveryCode.format(code).lowercased())  "
        #expect(CrockfordBase32.decode(messy).map { Array($0.prefix(16)) } == bytes)
    }

    @Test("rejects characters outside the alphabet")
    func rejectsCharactersOutsideTheAlphabet() {
        #expect(CrockfordBase32.decode(String(repeating: "U", count: 26)) == nil)
        #expect(CrockfordBase32.decode("hello world") == nil)
        #expect(CrockfordBase32.decode("") == nil)
    }

    @Test("formats into readable groups without changing the value")
    func formatsIntoReadableGroups() {
        let code = CrockfordBase32.encode(fill(0x42))
        #expect(code == "89144GJ289144GJ289144GJ288")
        #expect(RecoveryCode.format(code) == "89144-GJ289-144GJ-28914-4GJ28-8")
        #expect(CrockfordBase32.decode(RecoveryCode.format(code)) == CrockfordBase32.decode(code))
    }
}

// 03 §14.2 "Add tests for the subtle cases".
@Suite("base32 subtle cases")
struct Base32SubtleCaseTests {
    @Test("one valid character decodes to zero bytes, not nil")
    func oneCharacterIsZeroBytes() {
        #expect(CrockfordBase32.decode("Z") == [])
    }

    @Test("a 27-character code decodes to 16 bytes")
    func twentySevenCharacters() {
        #expect(CrockfordBase32.decode("89144GJ289144GJ289144GJ288X")?.count == 16)
    }

    @Test("the low bits of the 26th character are ignored")
    func trailingAliases() {
        let expected = CrockfordBase32.decode("89144GJ289144GJ289144GJ288")
        for last in ["9", "A", "B"] {
            #expect(CrockfordBase32.decode("89144GJ289144GJ289144GJ28" + last) == expected)
        }
    }

    @Test("an inner space makes the code invalid")
    func innerSpace() {
        #expect(CrockfordBase32.decode("89144GJ289 144GJ289144GJ288") == nil)
    }

    @Test("JS trim: newlines, NBSP and BOM are stripped, NEL is not")
    func jsTrim() {
        let code = "89144GJ289144GJ289144GJ288"
        #expect(CrockfordBase32.decode("\n\(code)\n")?.count == 16)
        #expect(CrockfordBase32.decode("\u{00A0}\(code)")?.count == 16)
        #expect(CrockfordBase32.decode("\u{FEFF}\(code)")?.count == 16)
        #expect(CrockfordBase32.decode("\u{0085}\(code)") == nil)
    }
}

@Suite("base32 parity (Fixtures/base32.json)")
struct Base32ParityTests {
    struct Encode: Decodable { let hex: String; let code: String }
    struct Decode: Decodable { let input: String; let hex: String? }
    struct Format: Decodable { let input: String; let formatRecoveryCode: String; let formatCode: String }
    struct Account: Decodable { let hex: String; let code: String; let formatted: String; let accountId: String }
    struct File: Decodable {
        let encode: [Encode]
        let decode: [Decode]
        let format: [Format]
        let accounts: [Account]
    }

    let file: File

    init() throws {
        file = try loadFixture("base32")
    }

    @Test("encode matches JS")
    func encodeMatchesJS() {
        for entry in file.encode {
            #expect(CrockfordBase32.encode(bytes(hex: entry.hex)) == entry.code, "\(entry.hex)")
        }
    }

    @Test("decode matches JS")
    func decodeMatchesJS() {
        for entry in file.decode {
            #expect(CrockfordBase32.decode(entry.input).map(toHex) == entry.hex, "\(scalarDump(entry.input))")
        }
    }

    @Test("formatting matches JS")
    func formatMatchesJS() {
        for entry in file.format {
            #expect(sameScalars(RecoveryCode.format(entry.input), entry.formatRecoveryCode), "\(scalarDump(entry.input))")
            #expect(sameScalars(formatCode(entry.input), entry.formatCode), "\(scalarDump(entry.input))")
        }
    }

    @Test("account ids match JS")
    func accountIdsMatchJS() {
        for entry in file.accounts {
            let secret = bytes(hex: entry.hex)
            #expect(CrockfordBase32.encode(secret) == entry.code)
            #expect(RecoveryCode.format(entry.code) == entry.formatted)
            #expect(deriveAccountId(secret) == entry.accountId, "\(entry.hex)")
        }
    }
}

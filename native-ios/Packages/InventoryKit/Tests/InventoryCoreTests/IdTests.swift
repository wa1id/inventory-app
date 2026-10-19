import Testing
@testable import InventoryCore

// Port of src/core/__tests__/id.test.ts, plus Fixtures/ids.json.

/// Returns the same bytes every time, like the RN tests' `configureRandomBytes(() => bytes)`.
struct FixedBytes: RandomByteSource {
    let bytes: [UInt8]
    func randomBytes(count: Int) -> [UInt8] { Array(bytes.prefix(count)) }
}

@Suite("newId")
struct NewIdTests {
    // RN: "throws until an RNG is configured". Natively there is no unconfigured
    // state: the default source is the system CSPRNG, which is always present.
    @Test("throws until an RNG is configured (native: the system CSPRNG is the default)")
    func usesTheSystemCSPRNGByDefault() throws {
        let pattern = try Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        let ids = (0..<100).map { _ in newId() }
        for id in ids {
            #expect(id.wholeMatch(of: pattern) != nil, "\(id)")
        }
        #expect(Set(ids).count == ids.count)
    }

    @Test("formats RFC 4122 version-4 UUIDs from the injected bytes")
    func formatsFromInjectedBytes() {
        let id = newId(using: FixedBytes(bytes: Array(0..<16)))
        #expect(id == "00010203-0405-4607-8809-0a0b0c0d0e0f")
    }
}

@Suite("newQrToken")
struct NewQrTokenTests {
    @Test("hex-encodes the injected 16 bytes")
    func hexEncodesTheInjectedBytes() {
        #expect(newQrToken(using: FixedBytes(bytes: Array(repeating: 0xAB, count: 16))) == "abababababababababababababababab")
    }

    @Test("system tokens are 32 lowercase hex characters and differ")
    func systemTokens() throws {
        let pattern = try Regex("^[0-9a-f]{32}$")
        let tokens = (0..<100).map { _ in newQrToken() }
        for token in tokens {
            #expect(token.wholeMatch(of: pattern) != nil)
        }
        #expect(Set(tokens).count == tokens.count)
    }
}

@Suite("ids parity (Fixtures/ids.json)")
struct IdsParityTests {
    struct Entry: Decodable { let hex: String; let id: String; let token: String }

    @Test("newId, newQrToken and toHex match JS")
    func matchesJS() throws {
        let entries: [Entry] = try loadFixture("ids")
        #expect(entries.count > 20)
        for entry in entries {
            let source = FixedBytes(bytes: bytes(hex: entry.hex))
            #expect(toHex(source.bytes) == entry.hex)
            #expect(newId(using: source) == entry.id)
            #expect(newQrToken(using: source) == entry.token)
        }
    }

    @Test("the system source returns exactly the requested count")
    func systemSourceCounts() {
        let source = SystemRandomByteSource()
        for count in [0, 1, 7, 8, 9, 16, 33] {
            #expect(source.randomBytes(count: count).count == count)
        }
    }

    #if canImport(Security)
    @Test("SecureRandom returns the requested count")
    func secureRandom() throws {
        #expect(try SecureRandom.bytes(count: 16).count == 16)
        #expect(try SecureRandom.bytes(count: 0).isEmpty)
        #expect(try SecureRandom.bytes(count: 16) != SecureRandom.bytes(count: 16))
    }
    #endif
}

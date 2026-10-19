import Foundation
import InventoryCore
import InventoryStorage
import Testing
@testable import InventoryServices

// Ports src/services/account/__tests__/identity.test.ts at the account level (the codec cases
// also live in InventoryCoreTests/Base32Tests), plus the 03 B8 fix and the 16-byte rule
// RecoveryCodeStore enforces (identity.ts:63-66).

private func secret(_ byte: UInt8) -> [UInt8] {
    Array(repeating: byte, count: RecoveryCode.secretByteCount)
}

@Suite("identity cross-implementation vectors")
struct SyncAccountVectorTests {
    @Test("encodes a known secret to the code the service expects")
    func encodesAKnownSecret() throws {
        let store = SyncAccountStore(keychain: InMemoryKeychain(), randomBytes: { _ in secret(0x42) })
        #expect(try store.create().recoveryCode == "89144GJ289144GJ289144GJ288")
    }

    @Test("derives the account id the service derives")
    func derivesTheAccountId() throws {
        let account = try #require(SyncAccount(storedCode: "89144GJ289144GJ289144GJ288"))
        #expect(account.id == "900dfeb7f1b5e344209e2abce56c333d")
    }
}

@Suite("identity recovery code encoding")
struct SyncAccountEncodingTests {
    @Test("round-trips random secrets")
    func roundTripsRandomSecrets() throws {
        for _ in 0..<50 {
            let keychain = InMemoryKeychain()
            let created = try SyncAccountStore(keychain: keychain).create()
            let decoded = try #require(CrockfordBase32.decode(created.recoveryCode))
            #expect(CrockfordBase32.encode(decoded.prefix(16)) == created.recoveryCode)
            #expect(deriveAccountId(decoded.prefix(16)) == created.id)
        }
    }

    @Test("survives the transcription mistakes it was chosen to survive")
    func survivesTranscriptionMistakes() throws {
        let code = CrockfordBase32.encode(secret(0x11))
        let retyped = RecoveryCode.format(code).lowercased()
            .replacingOccurrences(of: "1", with: "l")
            .replacingOccurrences(of: "0", with: "o")
        let adopted = try SyncAccountStore(keychain: InMemoryKeychain()).importAccount(retyped).get()
        #expect(adopted.recoveryCode == code)
    }
}

@Suite("identity account lifecycle")
struct SyncAccountLifecycleTests {
    @Test("reports no account on a device that has never had one")
    func noAccount() {
        let store = SyncAccountStore(keychain: InMemoryKeychain())
        #expect(store.load() == nil)
        #expect(store.lookup() == .absent)
    }

    @Test("creates an account and finds it again")
    func createsAndFinds() throws {
        let keychain = InMemoryKeychain()
        let store = SyncAccountStore(keychain: keychain)
        let created = try store.create()
        #expect(created.recoveryCode.count == 26)
        #expect(store.load() == created)
        #expect(keychain.values == [KeychainKey.recoveryCode: created.recoveryCode])
    }

    @Test("gives different devices different accounts")
    func differentDevicesDifferentAccounts() throws {
        let keychain = InMemoryKeychain()
        let store = SyncAccountStore(keychain: keychain)
        let first = try store.create()
        keychain.delete(forKey: KeychainKey.recoveryCode)
        let second = try store.create()
        #expect(second.id != first.id)
    }

    @Test("adopts an account from a code typed in any reasonable shape")
    func adoptsTypedCode() throws {
        let keychain = InMemoryKeychain()
        let store = SyncAccountStore(keychain: keychain)
        let original = try store.create()
        keychain.delete(forKey: KeychainKey.recoveryCode)

        let adopted = try store.importAccount(RecoveryCode.format(original.recoveryCode).lowercased()).get()
        // Same code means the same account, which is the entire restore path.
        #expect(adopted.id == original.id)
        // What gets persisted is canonical, never whatever was typed.
        #expect(adopted.recoveryCode == original.recoveryCode)
        #expect(keychain.values[KeychainKey.recoveryCode] == original.recoveryCode)
    }

    @Test("refuses a code that decodes to too few bytes")
    func refusesShortCode() {
        let keychain = InMemoryKeychain()
        let result = SyncAccountStore(keychain: keychain).importAccount("89144")
        #expect(result == .failure(.malformed))
        #expect(keychain.values.isEmpty)
    }

    @Test("refuses a code containing characters outside the alphabet")
    func refusesForeignCharacters() {
        let result = SyncAccountStore(keychain: InMemoryKeychain()).importAccount(String(repeating: "U", count: 26))
        #expect(result == .failure(.malformed))
    }

    @Test("reports an unwritable keystore rather than claiming success")
    func reportsUnwritableKeystore() {
        let keychain = InMemoryKeychain()
        keychain.failNextWrite()
        let code = CrockfordBase32.encode(secret(9))
        #expect(SyncAccountStore(keychain: keychain).importAccount(code) == .failure(.unavailable))
    }

    @Test("treats a keystore read failure as no account, not a new one")
    func readFailureIsNoAccount() throws {
        let keychain = InMemoryKeychain()
        let store = SyncAccountStore(keychain: keychain)
        let created = try store.create()
        keychain.failNextRead()
        // Minting a second account here would orphan the backups under the first.
        #expect(store.load() == nil)
        #expect(store.load() == created)
    }

    @Test("forgets an account without touching anything else")
    func forgets() throws {
        let keychain = InMemoryKeychain([KeychainKey.householdSession: "{}"])
        let store = SyncAccountStore(keychain: keychain)
        _ = try store.create()
        store.forget()
        #expect(store.load() == nil)
        #expect(keychain.values == [KeychainKey.householdSession: "{}"])
    }
}

@Suite("identity: unreadable keychain (03 B8)")
struct SyncAccountUnreadableKeychainTests {
    @Test("an unreadable keychain is told apart from an empty one")
    func lookupDistinguishesUnreadable() throws {
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: "89144GJ289144GJ289144GJ288"])
        let store = SyncAccountStore(keychain: keychain)
        keychain.failNextRead()
        #expect(store.lookup() == .unreadable(InMemoryKeychain.simulatedFailure))
        #expect(store.lookup() == .found(try #require(SyncAccount(storedCode: "89144GJ289144GJ289144GJ288"))))
    }

    @Test("Turn on never overwrites a code it could not read")
    func createRefusesWhenUnreadable() {
        let real = "89144GJ289144GJ289144GJ288"
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        keychain.failNextRead()
        #expect(throws: SyncAccountError.keychainUnreadable(InMemoryKeychain.simulatedFailure)) {
            try SyncAccountStore(keychain: keychain).create()
        }
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
    }

    @Test("Turn on uses an account that is already stored instead of minting a second one")
    func createKeepsExistingAccount() throws {
        let real = "89144GJ289144GJ289144GJ288"
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        let created = try SyncAccountStore(keychain: keychain, randomBytes: { _ in secret(0x01) }).create()
        #expect(created.recoveryCode == real)
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
    }

    @Test("an import never overwrites a code it could not read")
    func importRefusesWhenUnreadable() {
        let real = "89144GJ289144GJ289144GJ288"
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        keychain.failNextRead()
        let typed = CrockfordBase32.encode(secret(0x11))
        #expect(SyncAccountStore(keychain: keychain).importAccount(typed) == .failure(.unavailable))
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
    }

    @Test("a failing random source creates nothing")
    func randomFailureCreatesNothing() {
        let keychain = InMemoryKeychain()
        let store = SyncAccountStore(keychain: keychain, randomBytes: { _ in throw SyncAccountError.randomUnavailable(-1) })
        #expect(throws: SyncAccountError.randomUnavailable(-1)) { try store.create() }
        #expect(keychain.values.isEmpty)
    }

    @Test("a keychain that refuses the write creates nothing")
    func writeFailureCreatesNothing() {
        let keychain = InMemoryKeychain()
        keychain.failNextWrite()
        #expect(throws: SyncAccountError.keychainWriteFailed(InMemoryKeychain.simulatedFailure)) {
            try SyncAccountStore(keychain: keychain).create()
        }
        #expect(keychain.values.isEmpty)
    }
}

@Suite("RecoveryCodeStore: a stored code must decode to 16 bytes (identity.ts:63-66)")
struct SyncRecoveryCodeDecodeRuleTests {
    @Test("a stored code that decodes to the wrong length, or not at all, is no account", arguments: [
        "89144",                          // 3 bytes
        "89144GJ289144GJ289144GJ28800",   // 28 characters, 17 bytes
        String(repeating: "U", count: 26), // outside the alphabet
        "not a code",
    ])
    func undecodableIsAbsent(stored: String) throws {
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: stored])
        #expect(RecoveryCodeStore(keychain: keychain).load() == nil)
        #expect(try RecoveryCodeStore(keychain: keychain).loadReportingErrors() == nil)
        #expect(SyncAccountStore(keychain: keychain).lookup() == .absent)
        // Not deleted: RN leaves the item alone too.
        #expect(keychain.values[KeychainKey.recoveryCode] == stored)
    }

    @Test("a 27-character code decodes to 16 bytes and is accepted, as RN and the Worker accept it")
    func twentySevenCharacters() throws {
        let stored = "89144GJ289144GJ289144GJ2888"
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: stored])
        let account = try #require(SyncAccountStore(keychain: keychain).load())
        #expect(account.recoveryCode == stored)
        #expect(account.id == "900dfeb7f1b5e344209e2abce56c333d")
    }

    @Test("the account never prints its code or id")
    func redactedDescription() throws {
        let account = try #require(SyncAccount(storedCode: "89144GJ289144GJ289144GJ288"))
        for text in [String(describing: account), String(reflecting: account)] {
            #expect(!text.contains("89144"))
            #expect(!text.contains("900dfeb7"))
        }
        var dumped = ""
        dump(account, to: &dumped)
        #expect(!dumped.contains("89144"))
    }
}

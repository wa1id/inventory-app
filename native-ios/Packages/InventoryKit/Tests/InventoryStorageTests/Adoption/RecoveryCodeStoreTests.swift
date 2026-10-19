import Foundation
import Testing
@testable import InventoryStorage

/// The keychain parts of `src/services/account/__tests__/identity.test.ts` ("account lifecycle").
/// The codec, account-id and canonicalisation cases belong to the account area (03 §3.8), which
/// composes ``RecoveryCodeStore`` with the base32 codec.
@Suite("RecoveryCodeStore (identity.test.ts, keychain parts)")
struct RecoveryCodeStoreTests {
    /// 16 × 0x42 encoded (identity.test.ts:47-53).
    let code = "89144GJ289144GJ289144GJ288"

    @Test("reports no account on a device that has never had one")
    func noAccount() {
        let store = RecoveryCodeStore(keychain: InMemoryKeychain())
        #expect(store.load() == nil)
    }

    @Test("creates an account and finds it again")
    func createAndFind() throws {
        let keychain = InMemoryKeychain()
        let store = RecoveryCodeStore(keychain: keychain)
        try store.save(code)
        #expect(store.load()?.count == 26)
        #expect(store.load() == code)
        #expect(keychain.values == ["sync.accountSecret.v1": code])
    }

    @Test("reports an unwritable keystore rather than claiming success")
    func unwritable() {
        let keychain = InMemoryKeychain()
        let store = RecoveryCodeStore(keychain: keychain)
        keychain.failNextWrite()
        #expect(throws: KeychainError.self) { try store.save(code) }
        #expect(keychain.values.isEmpty)
    }

    @Test("treats a keystore read failure as no account, not a new one")
    func readFailure() throws {
        let keychain = InMemoryKeychain()
        let store = RecoveryCodeStore(keychain: keychain)
        try store.save(code)
        keychain.failNextRead()
        #expect(store.load() == nil)
        // Nothing was overwritten or removed: the next read finds the code again.
        #expect(store.load() == code)
        keychain.failNextRead()
        #expect(throws: KeychainError.self) { try store.loadReportingErrors() }
    }

    @Test("forgets an account without touching anything else")
    func forget() throws {
        let keychain = InMemoryKeychain([KeychainKey.householdSession: "{}"])
        let store = RecoveryCodeStore(keychain: keychain)
        try store.save(code)
        store.forget()
        #expect(store.load() == nil)
        #expect(keychain.values == [KeychainKey.householdSession: "{}"])
    }

    @Test("an empty stored value is no account (identity.ts:63)")
    func emptyValue() throws {
        let store = RecoveryCodeStore(keychain: InMemoryKeychain([KeychainKey.recoveryCode: ""]))
        #expect(store.load() == nil)
        #expect(try store.loadReportingErrors() == nil)
    }

    @Test("the stored code is returned exactly as written, not re-canonicalised (identity.ts:68)")
    func returnedAsStored() {
        let typed = "89144-gj289-144gj-28914-4gj28-8"
        let store = RecoveryCodeStore(keychain: InMemoryKeychain([KeychainKey.recoveryCode: typed]))
        #expect(store.load() == typed)
    }
}

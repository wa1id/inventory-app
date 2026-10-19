import InventoryCore
import Testing
@testable import InventoryAppModels

/// 09 §5 and §14.2 `InventoryQueryTests` (no RN tests exist for `useInventoryQuery`).
@Suite("InventoryQuery (src/hooks/useInventoryQuery.ts)")
@MainActor
struct InventoryQueryTests {
    private func settle<Value>(_ query: InventoryQuery<Value>) async {
        await query.readTask?.value
    }

    @Test("reads once when the screen appears focused, not twice as RN did on mount")
    func readsOnceOnAppear() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", revision: 3, read: reads.read)
        query.focusChanged(true)
        await settle(query)
        #expect(query.data == ["a"])
        #expect(!query.isLoading)
        #expect(query.cause == nil)
        #expect(!query.refreshFailed)
        #expect(reads.callCount == 1)
        #expect(query.trigger == QueryTrigger(key: "spaces", seenRevision: 3, localRevision: 1))
    }

    @Test("reads nothing before focus, a key change or reload, and counts as loading meanwhile")
    func nothingBeforeFocus() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.revisionChanged(1)
        query.focusChanged(false)
        await ShellWait.settle()
        #expect(reads.callCount == 0)
        #expect(query.isLoading)
        #expect(query.data == nil)
        #expect(query.dataKey == nil)
    }

    @Test("a nil (gone) result is data: no cause, not loading, and no stale-data banner")
    func goneIsData() async {
        let reads = ShellQueuedReads<String?>([.value(nil)])
        let query = InventoryQuery<String?>(key: "item:1", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        #expect(query.cause == nil)
        #expect(!query.isLoading)
        #expect(query.data == .some(nil))
        #expect(!query.refreshFailed)
    }

    @Test("a failed refresh keeps the same key's data, under the stale-data banner")
    func keepsSameKeyDataOnFailure() async {
        let reads = ShellQueuedReads<[String]>([.value(["a"]), .failure(ShellTestError("blip"))])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.reload()
        await settle(query)
        #expect(query.data == ["a"])
        #expect((query.cause as? ShellTestError) == ShellTestError("blip"))
        #expect(query.refreshFailed)
        #expect(!query.isLoading)
    }

    @Test("a failure for a different key drops the other key's data")
    func dropsOtherKeyDataOnFailure() async {
        let reads = ShellQueuedReads<[String]>([.value(["twelve"]), .failure(ShellTestError())])
        let query = InventoryQuery(key: "recent:12", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.setKey("recent:40")
        await settle(query)
        #expect(query.data == nil)
        #expect(query.cause != nil)
        #expect(!query.refreshFailed)
        #expect(query.dataKey == "recent:40")
    }

    @Test("data is not filtered by key: the old key's data stays while the new key loads")
    func dataNotFilteredByKey() async {
        let reads = ShellHeldReads<[String]>()
        let query = InventoryQuery(key: "recent:12", read: reads.read)
        query.focusChanged(true)
        await reads.waitForCalls(1)
        reads.succeed(["twelve"])
        await settle(query)

        query.setKey("recent:40")
        await reads.waitForCalls(2)
        #expect(query.data == ["twelve"])
        #expect(query.dataKey == "recent:12")
        #expect(query.isLoading)
        #expect(query.cause == nil)

        reads.succeed(["forty"])
        await settle(query)
        #expect(query.data == ["forty"])
        #expect(query.key == "recent:40")
    }

    @Test("a key change reads even while the screen is not focused, as RN re-ran on it")
    func keyChangeReadsUnfocused() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "space:1", read: reads.read)
        query.setKey("space:2")
        await settle(query)
        #expect(reads.callCount == 1)
        #expect(query.data == ["a"])
        query.setKey("space:2")
        await ShellWait.settle()
        #expect(reads.callCount == 1)
    }

    @Test("a write while unfocused does not read; focus catches up and reloads in one read")
    func revisionWhileUnfocused() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.focusChanged(false)
        query.revisionChanged(1)
        query.revisionChanged(2)
        await ShellWait.settle()
        #expect(reads.callCount == 1)
        #expect(query.trigger.seenRevision == 0)

        query.focusChanged(true)
        await settle(query)
        #expect(reads.callCount == 2)
        #expect(query.trigger == QueryTrigger(key: "spaces", seenRevision: 2, localRevision: 2))
    }

    @Test("focus can carry the newest revision; it is still one read")
    func focusCarriesRevision() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true, revision: 5)
        await settle(query)
        #expect(reads.callCount == 1)
        #expect(query.trigger.seenRevision == 5)
    }

    @Test("a write while focused reads once; the same revision again reads nothing")
    func revisionWhileFocused() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.revisionChanged(1)
        await settle(query)
        #expect(reads.callCount == 2)
        query.revisionChanged(1)
        query.focusChanged(true)
        await ShellWait.settle()
        #expect(reads.callCount == 2)
    }

    @Test("regaining focus reads again even without a write")
    func refocusReads() async {
        let reads = ShellQueuedReads(["a"])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.focusChanged(false)
        query.focusChanged(true)
        await settle(query)
        #expect(reads.callCount == 2)
    }

    @Test("reload reads again, focused or not")
    func reload() async {
        let reads = ShellQueuedReads<[String]>([.value(["a"]), .value(["b"])])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.reload()
        await settle(query)
        #expect(query.data == ["a"])
        query.reload()
        await settle(query)
        #expect(query.data == ["b"])
        #expect(reads.callCount == 2)
    }

    @Test("an answer for a superseded read is ignored")
    func staleResultIgnored() async {
        let reads = ShellHeldReads<[String]>()
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await reads.waitForCalls(1)
        query.reload()
        await reads.waitForCalls(2)

        reads.succeed(["stale"], call: 0)
        await ShellWait.settle()
        #expect(query.data == nil)
        #expect(query.isLoading)

        reads.succeed(["fresh"], call: 1)
        await settle(query)
        #expect(query.data == ["fresh"])
        #expect(!query.isLoading)
    }

    @Test("a read for a key that came back (A → B → A) is still superseded")
    func supersededEvenWhenTriggerReturns() async {
        let reads = ShellHeldReads<[String]>()
        let query = InventoryQuery(key: "A", read: reads.read)
        query.setKey("A2")
        await reads.waitForCalls(1)
        query.setKey("A")
        await reads.waitForCalls(2)
        query.setKey("A2")
        await reads.waitForCalls(3)
        reads.succeed(["first A2"], call: 0)
        await ShellWait.settle()
        #expect(query.data == nil)
        reads.succeed(["second A2"], call: 2)
        await settle(query)
        #expect(query.data == ["second A2"])
    }

    @Test("the cause belongs to the newest read only: a refresh in flight clears it")
    func causeOnlyForNewestRead() async {
        let reads = ShellHeldReads<[String]>()
        let query = InventoryQuery(key: "spaces", read: reads.read)
        query.focusChanged(true)
        await reads.waitForCalls(1)
        reads.succeed(["a"])
        await settle(query)
        query.reload()
        await reads.waitForCalls(2)
        reads.fail()
        await settle(query)
        #expect(query.cause != nil)
        #expect(query.refreshFailed)

        query.reload()
        await reads.waitForCalls(3)
        #expect(query.cause == nil)
        #expect(!query.refreshFailed)
        #expect(query.isLoading)
        #expect(query.data == ["a"])
        reads.succeed(["b"])
        await settle(query)
        #expect(query.cause == nil)
    }

    @Test("a failed refresh of a gone record shows the error, not a stale gone (JS null)")
    func goneRefreshFailure() async {
        let reads = ShellQueuedReads<String?>([.value(nil), .failure(ShellTestError())])
        let query = InventoryQuery<String?>(key: "item:1", read: reads.read)
        query.focusChanged(true)
        await settle(query)
        query.reload()
        await settle(query)
        #expect(query.cause != nil)
        #expect(!query.refreshFailed)
        #expect(query.data == .some(nil))
    }

    @Test("a new read closure is used from the next read and reads nothing by itself")
    func setRead() async {
        let local = ShellQueuedReads(["local"])
        let household = ShellQueuedReads(["household"])
        let query = InventoryQuery(key: "spaces", read: local.read)
        query.focusChanged(true)
        await settle(query)
        query.setRead(household.read)
        await ShellWait.settle()
        #expect(household.callCount == 0)
        query.revisionChanged(1)
        await settle(query)
        #expect(query.data == ["household"])
        #expect(local.callCount == 1)
    }

    @Test("refresh returns once the read it started has settled")
    func refreshAwaits() async {
        let reads = ShellQueuedReads<[String]>([.value(["a"]), .value(["b"])])
        let query = InventoryQuery(key: "spaces", read: reads.read)
        await query.refresh()
        #expect(query.data == ["a"])
        await query.refresh()
        #expect(query.data == ["b"])
    }
}

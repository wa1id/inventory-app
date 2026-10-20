import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a label screen model under test talks to.
@MainActor
final class LabelLinkHarness {
    let qr: ScanTestQr
    let invalidator = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let confirm: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let navigation = ScanTestNavigation<LabelLinkNavigation>()
    private(set) var remembered: [String] = []

    init(confirm: [Bool] = [], holdResolves: Bool = false, holdLookups: Bool = false, holdBinds: Bool = false) {
        qr = ScanTestQr(holdResolves: holdResolves, holdLookups: holdLookups, holdBinds: holdBinds)
        self.confirm = SharedSeamsConfirmScript(answers: confirm)
    }

    func model(token: String = ScanTestData.token) -> LabelLinkModel {
        let qr = qr
        return LabelLinkModel(
            token: token,
            qr: { qr },
            invalidator: invalidator,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry),
            rememberPlace: { [self] id in remembered.append(id) },
            navigate: navigation.navigate
        )
    }

    /// A model whose lookup found an unlinked label of ours.
    func unknownLabel() async -> LabelLinkModel {
        let model = model()
        model.start()
        await model.waitForLookup()
        telemetry.reset()
        return model
    }
}

private extension LabelLinkState {
    var name: String {
        switch self {
        case .resolving: "resolving"
        case .failed: "failed"
        case .invalid: "invalid"
        case .unknown(let token): "unknown:\(token)"
        }
    }
}

@Suite("LabelLinkModel: lookup (app/c/[token].tsx, 06 §9.1-9.2)", .timeLimit(.minutes(1)))
@MainActor
struct LabelLinkLookupTests {
    @Test("a linked label replaces the screen with its container")
    func bound() async {
        let harness = LabelLinkHarness()
        harness.qr.answer(ScanTestData.token, with: .success(.bound(container: ScanTestData.container("c9"), token: ScanTestData.token)))
        let model = harness.model()
        #expect(model.state.name == "resolving")
        model.start()
        model.start()
        await model.waitForLookup()
        #expect(harness.qr.resolved == [ScanTestData.token])
        #expect(model.state.name == "resolving")
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c9")])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "qr_deeplink", payload: ["outcome": .string("bound")])])
    }

    @Test("a label linked to the drop zone opens its tab")
    func boundDropZone() async {
        let harness = LabelLinkHarness()
        harness.qr.answer(ScanTestData.token, with: .success(.bound(container: ScanTestData.container(DropZone.containerId, name: nil, shortCode: "DROP"), token: ScanTestData.token)))
        let model = harness.model()
        model.start()
        await model.waitForLookup()
        #expect(harness.navigation.destinations == [.dropZoneTab])
    }

    @Test("an unlinked label of ours asks where it is stuck, with the lowercased token")
    func unknown() async {
        let harness = LabelLinkHarness()
        let model = harness.model(token: ScanTestData.token.uppercased())
        model.start()
        await model.waitForLookup()
        #expect(model.state.name == "unknown:\(ScanTestData.token)")
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.telemetry.events.map(\.payload) == [["outcome": .string("unknown")]])
    }

    @Test("not one of ours: the invalid state, whose action goes Home")
    func invalid() async {
        let harness = LabelLinkHarness()
        let model = harness.model(token: "hello")
        model.start()
        await model.waitForLookup()
        #expect(model.state.name == "invalid")
        #expect(harness.telemetry.events.map(\.payload) == [["outcome": .string("invalid")]])
        model.goHome()
        #expect(harness.navigation.destinations == [.home])
    }

    @Test("a failed lookup logs qr_deeplink_failed and offers Try again, which reads once more")
    func failedThenRetry() async {
        let harness = LabelLinkHarness()
        harness.qr.answer(ScanTestData.token, with: .failure(HouseholdHttpError(status: 502, code: "http_502")))
        let model = harness.model()
        model.start()
        await model.waitForLookup()
        #expect(model.state.name == "failed")
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "qr_deeplink_failed", payload: ["errorClass": .string("offline")])])

        harness.qr.answer(ScanTestData.token, with: .success(.unknown(token: ScanTestData.token)))
        model.retry()
        #expect(model.state.name == "resolving")
        await model.waitForLookup()
        #expect(harness.qr.resolved.count == 2)
        #expect(model.state.name == "unknown:\(ScanTestData.token)")
    }

    @Test("leaving before the answer: the late answer changes nothing and opens nothing")
    func lateAnswer() async {
        let harness = LabelLinkHarness(holdResolves: true)
        harness.qr.answer(ScanTestData.token, with: .success(.bound(container: ScanTestData.container(), token: ScanTestData.token)))
        let model = harness.model()
        model.start()
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.resolveLatch?.release()
        await captureTestSettle()
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.telemetry.entries.isEmpty)
    }

    @Test("a linked label whose container could not replace it yet replaces it once back in front")
    func replacesWhenBackInFront() async {
        let harness = LabelLinkHarness()
        harness.qr.answer(ScanTestData.token, with: .success(.bound(container: ScanTestData.container("c9"), token: ScanTestData.token)))
        let model = harness.model()
        model.start()
        await model.waitForLookup()
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c9")])

        // The screen was not on top (the router refused): it is asked again when it is in front.
        model.focusGained()
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c9"), .replaceWithContainer(id: "c9")])

        // Once replaced (removed), nothing more.
        model.close()
        model.focusGained()
        #expect(harness.navigation.destinations.count == 2)
    }

    @Test("focus alone opens nothing while the label is unknown, not ours, or in the drop zone")
    func focusOpensNothingElse() async {
        let harness = LabelLinkHarness()
        harness.qr.answer("hello", with: .success(.invalid(raw: "hello")))
        let invalid = harness.model(token: "hello")
        invalid.start()
        await invalid.waitForLookup()
        invalid.focusGained()

        let unknown = await harness.unknownLabel()
        unknown.focusGained()

        harness.qr.answer(ScanTestData.otherToken, with: .success(.bound(container: ScanTestData.container(DropZone.containerId, name: nil, shortCode: "DROP"), token: ScanTestData.otherToken)))
        let dropZone = harness.model(token: ScanTestData.otherToken)
        dropZone.start()
        await dropZone.waitForLookup()
        dropZone.focusGained()

        #expect(harness.navigation.destinations == [.dropZoneTab])
    }

    @Test("an answer for an older attempt is dropped")
    func olderAttempt() async {
        let harness = LabelLinkHarness(holdResolves: true)
        harness.qr.answer(ScanTestData.token, with: .failure(ScanTestError()))
        let model = harness.model()
        model.start()
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.retry()
        await harness.qr.resolveLatch?.waitForArrivals(2)
        await harness.qr.resolveLatch?.release()
        await captureTestSettle()
        #expect(model.state.name == "resolving")
        #expect(harness.telemetry.entries.isEmpty)
        await harness.qr.resolveLatch?.release()
        await model.waitForLookup()
        #expect(model.state.name == "failed")
        #expect(harness.telemetry.entries.count == 1)
    }
}

@Suite("LabelLinkModel: linking (06 §9.3)", .timeLimit(.minutes(1)))
@MainActor
struct LabelLinkLinkTests {
    @Test("a container without a label is linked at once: bind, qr_bound, invalidate, remember, open it, say so")
    func linksStraightAway() async {
        let harness = LabelLinkHarness()
        let model = await harness.unknownLabel()

        await model.link(ScanTestData.option("c1"))

        #expect(harness.qr.lookups == ["c1"])
        #expect(harness.confirm.asked.isEmpty)
        #expect(harness.qr.bound.map(\.token) == [ScanTestData.token])
        #expect(harness.qr.bound.map(\.containerId) == ["c1"])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "qr_bound")])
        #expect(harness.invalidator.count == 1)
        #expect(harness.remembered == ["c1"])
        #expect(harness.haptics.played == [.success])
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c1")])
        #expect(harness.toasts.messages == ["Label linked to Tool chest."])
        #expect(harness.toasts.last?.tone == .info)
        // The list stays locked: the screen is being replaced.
        #expect(model.busyId == "c1")
        await model.link(ScanTestData.option("c2"))
        #expect(harness.qr.lookups == ["c1"])
        // Not replaced yet (another screen was on top): back in front, the container opens.
        model.focusGained()
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c1"), .replaceWithContainer(id: "c1")])
        #expect(harness.qr.bound.count == 1, "nothing is written again")
    }

    @Test("a label linked to that container meanwhile writes nothing but still opens it and says so")
    func linkedMeanwhile() async {
        let harness = LabelLinkHarness()
        harness.qr.setExisting(ScanTestData.binding(ScanTestData.token.uppercased()), for: "c1")
        let model = await harness.unknownLabel()
        await model.link(ScanTestData.option("c1", name: nil, shortCode: "BIN-4F2A"))
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.telemetry.entries.isEmpty)
        #expect(harness.invalidator.count == 0)
        #expect(harness.remembered == ["c1"])
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c1")])
        #expect(harness.toasts.messages == ["Label linked to BIN-4F2A."])
    }

    @Test("replacing the container's own label asks first; Replace links it")
    func replaceConfirmed() async {
        let harness = LabelLinkHarness(confirm: [true])
        harness.qr.setExisting(ScanTestData.binding(ScanTestData.otherToken), for: "c1")
        let model = await harness.unknownLabel()
        await model.link(ScanTestData.option("c1"))
        #expect(harness.confirm.asked == [ConfirmOptions(
            title: "Replace the label on Tool chest?",
            body: "Tool chest already has a label. Its old sticker will stop opening it.",
            confirmLabel: "Replace"
        )])
        #expect(harness.qr.bound.map(\.containerId) == ["c1"])
        #expect(harness.navigation.destinations == [.replaceWithContainer(id: "c1")])
    }

    @Test("Cancel on the replace question writes nothing and unlocks the list")
    func replaceCancelled() async {
        let harness = LabelLinkHarness(confirm: [false])
        harness.qr.setExisting(ScanTestData.binding(ScanTestData.otherToken), for: "c1")
        let model = await harness.unknownLabel()
        await model.link(ScanTestData.option("c1"))
        #expect(harness.qr.bound.isEmpty)
        #expect(model.busyId == nil)
        #expect(harness.remembered.isEmpty)
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.toasts.shown.isEmpty)
        // Picking again asks again.
        await model.link(ScanTestData.option("c1"))
        #expect(harness.confirm.asked.count == 2)
    }

    @Test("a failed link logs qr_bind_failed, plays the error haptic, says why, and lets her try again")
    func failure() async {
        let harness = LabelLinkHarness()
        harness.qr.bindError = HouseholdHttpError(status: 404, code: "not_found")
        let model = await harness.unknownLabel()
        await model.link(ScanTestData.option("c1"))
        #expect(model.busyId == nil)
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "qr_bind_failed", payload: ["errorClass": .string("gone")])])
        #expect(harness.haptics.played == [.error])
        #expect(harness.toasts.messages == ["That container is not in the household any more. Choose another one."])
        #expect(harness.toasts.last?.tone == .error)
        #expect(harness.navigation.destinations.isEmpty)
        #expect(model.state.name == "unknown:\(ScanTestData.token)")

        harness.qr.bindError = nil
        harness.qr.getError = HouseholdHttpError(status: 0, code: "offline")
        await model.link(ScanTestData.option("c1"))
        #expect(harness.toasts.messages.last == "The label was not linked. Check the connection and try again.")
        #expect(harness.telemetry.entries.last?.payload == ["errorClass": .string("offline")])
    }

    @Test("leaving while the container's label is read: nothing is written")
    func leftBeforeWrite() async {
        let harness = LabelLinkHarness(holdLookups: true)
        let model = await harness.unknownLabel()
        let link = Task { await model.link(ScanTestData.option("c1")) }
        await harness.qr.lookupLatch?.waitForArrivals(1)
        #expect(model.busyId == "c1")
        model.close()
        await harness.qr.lookupLatch?.release()
        await link.value
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.toasts.shown.isEmpty)
        #expect(harness.navigation.destinations.isEmpty)
    }

    @Test("leaving while the link is written: still linked and said, but nothing opens")
    func leftDuringWrite() async {
        let harness = LabelLinkHarness(holdBinds: true)
        let model = await harness.unknownLabel()
        let link = Task { await model.link(ScanTestData.option("c1")) }
        await harness.qr.bindLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.bindLatch?.release()
        await link.value
        #expect(harness.qr.bound.count == 1)
        #expect(harness.toasts.messages == ["Label linked to Tool chest."])
        #expect(harness.remembered == ["c1"])
        #expect(harness.navigation.destinations.isEmpty)
    }

    @Test("a second pick while a link runs is ignored")
    func singleFlight() async {
        let harness = LabelLinkHarness(holdLookups: true)
        let model = await harness.unknownLabel()
        let link = Task { await model.link(ScanTestData.option("c1")) }
        await harness.qr.lookupLatch?.waitForArrivals(1)
        await model.link(ScanTestData.option("c2"))
        await harness.qr.lookupLatch?.release()
        await link.value
        #expect(harness.qr.lookups == ["c1"])
        #expect(harness.qr.bound.map(\.containerId) == ["c1"])
    }
}

import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a QR label screen model under test talks to.
@MainActor
final class LabelsQrLabelHarness {
    let qr: ScanTestQr
    let containers: LabelsTestContainerRead
    let invalidator = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let confirm: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()

    /// - Parameter label: the token of the label the container has on arrival, if any.
    init(
        container: ContainerWithCounts? = LabelsTestData.container(),
        label: String? = nil,
        confirm: [Bool] = [],
        holdLookups: Bool = false,
        holdWrites: Bool = false,
        holdContainer: Bool = false
    ) {
        qr = ScanTestQr(holdLookups: holdLookups, holdWrites: holdWrites)
        containers = LabelsTestContainerRead(container, hold: holdContainer)
        self.confirm = SharedSeamsConfirmScript(answers: confirm)
        if let label { qr.setExisting(ScanTestData.binding(label), for: "c1") }
    }

    func model() -> QrLabelModel {
        let containers = containers
        let qr = qr
        return QrLabelModel(
            containerId: "c1",
            reads: QrLabelModel.Reads(
                container: { try await containers.read($0)?.container },
                binding: { try await qr.getByContainer($0) }
            ),
            qr: { qr },
            invalidator: invalidator,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }

    /// A model in front whose two reads have come back.
    func loaded() async -> QrLabelModel {
        let model = model()
        model.focusChanged(true, revision: 0)
        await Self.settled(model)
        return model
    }

    /// Waits for both reads to come back.
    static func settled(_ model: QrLabelModel) async {
        await model.container.readTask?.value
        await model.binding.readTask?.value
    }
}

/// A label change that fails, and the toast that says so.
struct LabelsQrFailureCase: Sendable, CustomTestStringConvertible {
    var action: QrLabelAction
    var cause: any Error
    var message: String

    var testDescription: String { "\(action) after \(cause)" }

    static let all: [LabelsQrFailureCase] = [
        LabelsQrFailureCase(action: .make, cause: LabelsTestData.ReadFailure(), message: "The label was not made. Try again."),
        LabelsQrFailureCase(action: .replace, cause: LabelsTestData.offline, message: "The label was not replaced, so the old sticker still works. Check the connection and try again."),
        LabelsQrFailureCase(action: .remove, cause: HouseholdHttpError(status: 500, code: "http_500"), message: "The label was not removed, so the sticker still opens this container. Try again."),
        LabelsQrFailureCase(action: .make, cause: LabelsTestData.notFound, message: "This container is not in the household any more. Nothing else changed."),
    ]
}

extension QrLabelScreenState {
    /// A name to compare in tests.
    var labelsName: String {
        switch self {
        case .loading: "loading"
        case .containerFailed: "containerFailed"
        case .containerGone: "containerGone"
        case .labelFailed: "labelFailed"
        case .noLabel(let container): "noLabel:\(container.id)"
        case .label(let container, let token): "label:\(container.id):\(token)"
        }
    }
}

@Suite("QrLabelModel: reading (app/container/[id]/qr.tsx, 07 §3.9)", .timeLimit(.minutes(1)))
@MainActor
struct LabelsQrLabelReadTests {
    @Test("nothing is offered until both the container and its label have been read")
    func waitsForBoth() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, holdLookups: true)
        let model = harness.model()
        #expect(model.state.labelsName == "loading")
        model.focusChanged(true, revision: 0)
        await model.container.readTask?.value
        await harness.qr.lookupLatch?.waitForArrivals(1)
        #expect(!model.labelKnown)
        #expect(model.state.labelsName == "loading")

        await harness.qr.lookupLatch?.release()
        await model.binding.readTask?.value
        #expect(model.labelKnown)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")
        #expect(model.shownToken == ScanTestData.token)
        #expect(!model.showsRefreshBanner)
    }

    @Test("a container with no label offers to make one")
    func noLabel() async {
        let harness = LabelsQrLabelHarness()
        let model = await harness.loaded()
        #expect(model.state.labelsName == "noLabel:c1")
        #expect(model.container.key == "container:c1")
        #expect(model.binding.key == "qr-of:c1")
    }

    @Test("a container that is gone says so")
    func gone() async {
        let harness = LabelsQrLabelHarness(container: nil)
        let model = await harness.loaded()
        #expect(model.state.labelsName == "containerGone")
    }

    @Test("a container that cannot be read shows the error, and Try again reads both again")
    func containerFailed() async {
        let harness = LabelsQrLabelHarness()
        harness.containers.answer(.failure(LabelsTestData.offline))
        let model = await harness.loaded()
        #expect(model.state.labelsName == "containerFailed")
        #expect(harness.containers.reads == 1)
        #expect(harness.qr.lookups == ["c1"])

        harness.containers.answer(.success(LabelsTestData.container()))
        model.reloadAll()
        #expect(model.state.labelsName == "loading")
        await LabelsQrLabelHarness.settled(model)
        #expect(harness.containers.reads == 2)
        #expect(harness.qr.lookups == ["c1", "c1"])
        #expect(model.state.labelsName == "noLabel:c1")
    }

    @Test("not knowing whether there is a label is said as such, never with Make")
    func labelFailed() async {
        let harness = LabelsQrLabelHarness()
        harness.qr.getError = LabelsTestData.offline
        let model = await harness.loaded()
        #expect(model.state.labelsName == "labelFailed")
        #expect(!model.labelKnown)

        // A label read that failed after a good one keeps what was shown, under the banner.
        harness.qr.getError = nil
        model.reloadAll()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "noLabel:c1")
        harness.qr.getError = LabelsTestData.ReadFailure()
        model.reloadAll()
        await LabelsQrLabelHarness.settled(model)
        // "No label" read before is still null data: whether there is one is unknown again.
        #expect(model.state.labelsName == "labelFailed")
    }

    @Test("a refresh that fails keeps the label on screen under the refresh banner; offline has its own")
    func refreshBanner() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token)
        let model = await harness.loaded()
        harness.qr.getError = LabelsTestData.ReadFailure()
        model.revisionChanged(1)
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")
        #expect(model.showsRefreshBanner)

        harness.qr.getError = LabelsTestData.offline
        model.reloadAll()
        await LabelsQrLabelHarness.settled(model)
        #expect(!model.showsRefreshBanner)

        harness.qr.getError = nil
        harness.containers.answer(.failure(LabelsTestData.ReadFailure()))
        model.reloadAll()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")
        #expect(model.showsRefreshBanner)
    }

    @Test("reads follow focus: a screen behind reads again only when it is in front")
    func focus() async {
        let harness = LabelsQrLabelHarness()
        let model = await harness.loaded()
        model.focusChanged(false, revision: nil)
        model.revisionChanged(3)
        #expect(harness.containers.reads == 1)
        model.focusChanged(true, revision: 3)
        await LabelsQrLabelHarness.settled(model)
        #expect(harness.containers.reads == 2)
        #expect(harness.qr.lookups.count == 2)
    }
}

@Suite("QrLabelModel: making, replacing and removing (07 §3.9)", .timeLimit(.minutes(1)))
@MainActor
struct LabelsQrLabelWriteTests {
    @Test("Make binds a fresh label: qr_generated, invalidate, the success haptic, the label shown, no toast")
    func make() async {
        let harness = LabelsQrLabelHarness()
        let model = await harness.loaded()
        await model.make()
        let made = ScanTestQr.madeToken(1)
        #expect(harness.qr.created == ["c1"])
        #expect(harness.telemetry.names == ["qr_generated"])
        #expect(harness.invalidator.count == 1)
        #expect(harness.haptics.played == [.success])
        #expect(harness.toasts.messages.isEmpty)
        #expect(harness.confirm.asked.isEmpty)
        #expect(model.state.labelsName == "label:c1:\(made)")
        #expect(model.busy == nil)
        await LabelsQrLabelHarness.settled(model)
        #expect(model.written == nil)
        #expect(model.state.labelsName == "label:c1:\(made)")
    }

    @Test("Make looks first: a label linked meanwhile is shown with a toast, and none is made")
    func makeFindsOne() async {
        let harness = LabelsQrLabelHarness()
        let model = await harness.loaded()
        #expect(model.state.labelsName == "noLabel:c1")
        harness.qr.setExisting(ScanTestData.binding(ScanTestData.otherToken), for: "c1")

        await model.make()
        #expect(harness.qr.created.isEmpty)
        #expect(harness.toasts.messages == ["This container already has a label, so no new one was made."])
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.telemetry.names.isEmpty)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.otherToken)")
    }

    @Test("the label just made holds until a read started after it comes back, so No label never flashes")
    func holdsTheWrite() async {
        let harness = LabelsQrLabelHarness(holdLookups: true)
        let model = harness.model()
        model.focusChanged(true, revision: 0)
        await harness.qr.lookupLatch?.waitForArrivals(1)
        await harness.qr.lookupLatch?.release()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "noLabel:c1")

        // The write's own read (lookup 2, inside make) and the screen's re-read are held.
        let making = Task { await model.make() }
        await harness.qr.lookupLatch?.waitForArrivals(2)
        await harness.qr.lookupLatch?.release()
        await making.value
        let made = ScanTestQr.madeToken(1)
        #expect(model.written == WrittenLabel(token: made, reloading: true))
        #expect(model.state.labelsName == "label:c1:\(made)")

        // The view reports the revision bump: another read; still the written label.
        model.revisionChanged(1)
        #expect(model.state.labelsName == "label:c1:\(made)")
        await harness.qr.lookupLatch?.waitForArrivals(3)
        await harness.qr.lookupLatch?.release()
        await harness.qr.lookupLatch?.waitForArrivals(4)
        await harness.qr.lookupLatch?.release()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.written == nil)
        #expect(model.state.labelsName == "label:c1:\(made)")
    }

    @Test("a read already running when the label is replaced never brings the retired label back")
    func staleReadAfterTheWrite() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [true], holdLookups: true)
        let model = harness.model()
        model.focusChanged(true, revision: 0)
        await harness.qr.lookupLatch?.waitForArrivals(1)
        await harness.qr.lookupLatch?.release()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")

        // A write elsewhere: the label is read again, and that read (of the old label) is slow.
        model.revisionChanged(1)
        await harness.qr.lookupLatch?.waitForArrivals(2)

        // Replace runs meanwhile; the view has not reported its revision bump yet.
        await model.replace()
        let made = ScanTestQr.madeToken(1)
        #expect(model.state.labelsName == "label:c1:\(made)")

        // The slow read answers the retired label: it must not end the hold.
        await harness.qr.lookupLatch?.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.state.labelsName == "label:c1:\(made)", "the retired label came back")
        #expect(model.written?.token == made)

        // The read set off by the write answers the new label and ends the hold.
        await harness.qr.lookupLatch?.waitForArrivals(3)
        await harness.qr.lookupLatch?.release()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.written == nil)
        #expect(model.state.labelsName == "label:c1:\(made)")
    }

    @Test("a read that fails after a write keeps the written label, never the retired one, and no banner")
    func failedReadKeepsTheWrite() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [true])
        let model = await harness.loaded()
        harness.qr.getError = LabelsTestData.ReadFailure()
        await model.replace()
        await LabelsQrLabelHarness.settled(model)
        let made = ScanTestQr.madeToken(1)
        #expect(model.written == WrittenLabel(token: made, reloading: false))
        #expect(model.state.labelsName == "label:c1:\(made)")
        #expect(!model.showsRefreshBanner)

        // A later read that works ends the hold.
        harness.qr.getError = nil
        model.reloadAll()
        await LabelsQrLabelHarness.settled(model)
        #expect(model.written == nil)
        #expect(model.state.labelsName == "label:c1:\(made)")
    }

    @Test("Replace asks first; Cancel changes nothing")
    func replaceCancelled() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [false])
        let model = await harness.loaded()
        await model.replace()
        #expect(harness.confirm.asked == [ConfirmOptions(
            title: "Replace this label?",
            body: "The current sticker will stop opening this container. Only do this if the label is lost or damaged.",
            confirmLabel: "Replace"
        )])
        #expect(harness.confirm.asked.first?.destructive == true)
        #expect(harness.qr.created.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
        #expect(model.busy == nil)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")
    }

    @Test("Replace makes a new label and says to print it")
    func replace() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [true])
        let model = await harness.loaded()
        await model.replace()
        await LabelsQrLabelHarness.settled(model)
        #expect(harness.qr.created == ["c1"])
        #expect(harness.qr.lookups == ["c1", "c1"], "no look before a replace, only the read after it")
        #expect(harness.telemetry.names == ["qr_generated"])
        #expect(harness.haptics.played == [.success])
        #expect(harness.toasts.messages == ["New label made. Print it and replace the old sticker."])
        #expect(model.state.labelsName == "label:c1:\(ScanTestQr.madeToken(1))")
    }

    @Test("Remove asks first, unlinks the sticker, then shows No label and says so")
    func remove() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [true])
        let model = await harness.loaded()
        await model.remove()
        #expect(harness.confirm.asked.map(\.title) == ["Remove this label?"])
        #expect(harness.confirm.asked.first?.body == "The container and everything in it stay exactly as they are. The sticker just stops opening it.")
        #expect(harness.confirm.asked.first?.confirmLabel == "Remove")
        #expect(harness.qr.unbound == ["c1"])
        #expect(harness.telemetry.names == ["qr_unbound"])
        #expect(harness.invalidator.count == 1)
        #expect(harness.haptics.played == [.success])
        #expect(harness.toasts.messages == ["Label removed."])
        #expect(model.state.labelsName == "noLabel:c1")
        await LabelsQrLabelHarness.settled(model)
        #expect(model.state.labelsName == "noLabel:c1")
    }

    @Test("Remove cancelled writes nothing")
    func removeCancelled() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [false])
        let model = await harness.loaded()
        await model.remove()
        #expect(harness.qr.unbound.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
        #expect(model.state.labelsName == "label:c1:\(ScanTestData.token)")
    }

    @Test("a change that fails plays the error haptic and says what still holds", arguments: LabelsQrFailureCase.all)
    func failures(_ failure: LabelsQrFailureCase) async {
        let action = failure.action
        let cause = failure.cause
        let message = failure.message
        let harness = LabelsQrLabelHarness(label: action == .make ? nil : ScanTestData.token, confirm: [true])
        harness.qr.createError = cause
        harness.qr.unbindError = cause
        let model = await harness.loaded()
        switch action {
        case .make: await model.make()
        case .replace: await model.replace()
        case .remove: await model.remove()
        }
        #expect(harness.haptics.played == [.error])
        #expect(harness.toasts.shown.map(\.options.message) == [message])
        #expect(harness.toasts.last?.tone == .error)
        #expect(harness.telemetry.names.isEmpty)
        #expect(harness.invalidator.count == 0)
        #expect(model.busy == nil)
        #expect(model.written == nil)
    }

    @Test("one change at a time: the busy action spins, and a second tap does nothing")
    func oneAtATime() async {
        let harness = LabelsQrLabelHarness(label: ScanTestData.token, confirm: [true, true], holdWrites: true)
        let model = await harness.loaded()
        let replacing = Task { await model.replace() }
        await harness.qr.writeLatch?.waitForArrivals(1)
        #expect(model.busy == .replace)
        await model.remove()
        await model.make()
        #expect(harness.confirm.asked.count == 1)

        await harness.qr.writeLatch?.release()
        await replacing.value
        #expect(model.busy == nil)
        #expect(harness.qr.created == ["c1"])
        #expect(harness.qr.unbound.isEmpty)
    }
}

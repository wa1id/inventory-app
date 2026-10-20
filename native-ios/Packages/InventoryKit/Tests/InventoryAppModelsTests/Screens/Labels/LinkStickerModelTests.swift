import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a sticker-link model under test talks to.
@MainActor
final class LabelsLinkStickerHarness {
    let qr: ScanTestQr
    let containers: LabelsTestContainerRead
    let invalidator = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let confirm: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let navigation = ScanTestNavigation<LinkStickerNavigation>()
    let clock = ManualClock()

    init(
        container: ContainerWithCounts? = LabelsTestData.container(),
        confirm: [Bool] = [],
        holdResolves: Bool = false,
        holdBinds: Bool = false,
        holdContainer: Bool = false
    ) {
        qr = ScanTestQr(holdResolves: holdResolves, holdBinds: holdBinds)
        containers = LabelsTestContainerRead(container, hold: holdContainer)
        self.confirm = SharedSeamsConfirmScript(answers: confirm)
    }

    func model(containerId: String = "c1") -> LinkStickerModel {
        let containers = containers
        let qr = qr
        let model = LinkStickerModel(
            containerId: containerId,
            permission: ScanTestData.permission(),
            read: { try await containers.read($0) },
            qr: { qr },
            invalidator: invalidator,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry),
            clock: clock,
            navigate: navigation.navigate
        )
        model.scanner.reduceMotion = true
        return model
    }

    /// A cover in front whose container has been read; the scanner is focused as the view does.
    func loaded(containerId: String = "c1") async -> LinkStickerModel {
        let model = model(containerId: containerId)
        model.focusChanged(true, revision: 0)
        model.scanner.focusGained()
        await model.container.readTask?.value
        return model
    }
}

extension LinkStickerPhase {
    var labelsName: String {
        switch self {
        case .scanning: "scanning"
        case .checking: "checking"
        case .deciding: "deciding"
        case .linking: "linking"
        case .notOurs: "notOurs"
        case .failed: "failed"
        }
    }
}

@Suite("LinkStickerModel: the camera and its notices (app/container/[id]/link.tsx, 07 §3.10)", .timeLimit(.minutes(1)))
@MainActor
struct LabelsLinkStickerPanelTests {
    @Test("the camera waits for the container, then runs; the title names it")
    func waitsForTheContainer() async {
        let harness = LabelsLinkStickerHarness(holdContainer: true)
        let model = harness.model()
        model.focusChanged(true, revision: 0)
        model.scanner.focusGained()
        #expect(model.title == "Scan the sticker")
        #expect(!model.isActive)
        #expect(!model.scanner.cameraRuns)
        #expect(model.panel == nil, "nothing while it loads")

        await harness.containers.latch?.waitForArrivals(1)
        await harness.containers.latch?.release()
        await model.container.readTask?.value
        #expect(model.title == "Scan the sticker for Tool chest")
        #expect(model.isActive)
        #expect(model.scanner.cameraRuns)
        #expect(model.panel == nil)
    }

    @Test("an unnamed container is called by its code")
    func unnamed() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(name: "  ", shortCode: "BOX-7K2M"))
        let model = await harness.loaded()
        #expect(model.title == "Scan the sticker for BOX-7K2M")
    }

    @Test("the drop zone is locked: no camera, and the notice goes to its tab")
    func locked() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(DropZone.containerId, name: "Drop zone", shortCode: "DROP-ZONE"))
        let model = await harness.loaded(containerId: DropZone.containerId)
        #expect(model.isLocked)
        #expect(!model.isActive)
        #expect(model.panel?.tone == .error)
        #expect(model.panel?.title == "The drop zone cannot be changed")
        #expect(model.panel?.message == "It is where new items wait to be filed.")
        #expect(model.panel?.action == .goToDropZone)
        #expect(model.panel?.action?.label == "Go to the drop zone")
        #expect(model.panel?.action?.identifier == "link-drop-zone")
        model.perform(.goToDropZone)
        #expect(harness.navigation.destinations == [.dropZoneTab])
    }

    @Test("a container that cannot be read says so with Try again, which reads it again")
    func containerFailed() async {
        let harness = LabelsLinkStickerHarness()
        harness.containers.answer(.failure(LabelsTestData.offline))
        let model = await harness.loaded()
        #expect(!model.isActive)
        #expect(model.panel?.tone == .error)
        #expect(model.panel?.title == describeError(LabelsTestData.offline, context: .read, subject: .container).title)
        #expect(model.panel?.action == .reloadContainer)
        #expect(model.panel?.action?.identifier == "link-try-again")

        harness.containers.answer(.success(LabelsTestData.container()))
        model.perform(.reloadContainer)
        await model.container.readTask?.value
        #expect(harness.containers.reads == 2)
        #expect(model.panel == nil)
        #expect(model.isActive)
    }

    @Test("a container deleted meanwhile says so with Go back, which closes the camera")
    func gone() async {
        let harness = LabelsLinkStickerHarness(container: nil)
        let model = await harness.loaded()
        #expect(model.panel?.title == "This container is not in the household any more")
        #expect(model.panel?.message == "It was deleted, probably on another phone. Nothing else changed.")
        #expect(model.panel?.action == .goBack)
        #expect(model.panel?.action?.identifier == "link-back")
        #expect(model.panel?.announcement == "This container is not in the household any more. It was deleted, probably on another phone. Nothing else changed.")
        model.perform(.goBack)
        #expect(harness.navigation.destinations == [.close])
    }

    @Test("Reading the sticker… shows only once the lookup has run 180 ms")
    func checkingDelay() async throws {
        let harness = LabelsLinkStickerHarness(holdResolves: true)
        let model = await harness.loaded()
        let linking = Task { await model.link("anything") }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        #expect(model.phase.labelsName == "checking")
        #expect(model.isActive, "the camera stays on, paused")
        #expect(model.panel == nil)
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(179))
        #expect(model.panel == nil)
        await harness.clock.advance(by: .milliseconds(1))
        #expect(model.panel?.tone == .busy)
        #expect(model.panel?.message == "Reading the sticker…")
        #expect(model.panel?.action == nil)

        await harness.qr.resolveLatch?.release()
        await linking.value
        #expect(!model.showsChecking)
    }
}

@Suite("LinkStickerModel: linking (07 §3.10, §5.5)", .timeLimit(.minutes(1)))
@MainActor
struct LabelsLinkStickerLinkTests {
    static let payload = formatQrPayload(ScanTestData.token)

    @Test("not one of ours: the error haptic and the notice; Scan again turns the camera back on")
    func notOurs() async {
        let harness = LabelsLinkStickerHarness()
        let model = await harness.loaded()
        await model.link("https://example.com")
        #expect(model.phase.labelsName == "notOurs")
        #expect(harness.haptics.played == [.error])
        #expect(!model.isActive)
        #expect(model.panel?.title == "Not one of our labels")
        #expect(model.panel?.message == "That code was not made by this app.")
        #expect(model.panel?.action == .scanAgain)
        #expect(model.panel?.action?.label == "Scan again")
        #expect(model.panel?.action?.identifier == "link-scan-again")
        #expect(harness.qr.bound.isEmpty)

        model.perform(.scanAgain)
        #expect(model.phase.labelsName == "scanning")
        #expect(model.isActive)
        #expect(model.panel == nil)
    }

    @Test("a sticker that already opens this container closes with a toast and the success haptic")
    func already() async {
        let harness = LabelsLinkStickerHarness()
        harness.qr.answer(Self.payload, with: .success(.bound(container: ScanTestData.container("c1"), token: ScanTestData.token)))
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(harness.haptics.played == [.success])
        #expect(harness.navigation.destinations == [.close])
        #expect(harness.toasts.messages == ["This sticker already opens Tool chest."])
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.telemetry.names.isEmpty)
        #expect(harness.confirm.asked.isEmpty)
    }

    @Test("a new sticker on a container without a label links at once: bind, qr_bound, invalidate, close, toast")
    func linksAtOnce() async {
        let harness = LabelsLinkStickerHarness()
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(harness.confirm.asked.isEmpty)
        #expect(harness.qr.bound.map(\.token) == [ScanTestData.token])
        #expect(harness.qr.bound.map(\.containerId) == ["c1"])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "qr_bound")])
        #expect(harness.invalidator.count == 1)
        #expect(harness.haptics.played == [.success])
        #expect(harness.navigation.destinations == [.close])
        #expect(harness.toasts.messages == ["Sticker linked to Tool chest."])
        #expect(harness.toasts.last?.tone == .info)
    }

    @Test("replacing the container's own label asks first; Cancel goes back to scanning and writes nothing")
    func replaceCancelled() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(qrToken: ScanTestData.otherToken), confirm: [false])
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(harness.confirm.asked == [ConfirmOptions(
            title: "Replace the label on Tool chest?",
            body: "Tool chest already has a label. Its old sticker will stop opening it.",
            confirmLabel: "Replace"
        )])
        #expect(model.phase.labelsName == "scanning")
        #expect(model.isActive)
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
    }

    @Test("the camera is off while the question is up")
    func decidingStopsTheCamera() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(qrToken: ScanTestData.otherToken))
        let held = LabelsHeldConfirm()
        let model = LinkStickerModel(
            containerId: "c1",
            permission: ScanTestData.permission(),
            read: { [containers = harness.containers] in try await containers.read($0) },
            qr: { [qr = harness.qr] in qr },
            invalidator: harness.invalidator,
            toasts: harness.toasts,
            confirm: held,
            haptics: harness.haptics.player,
            clock: harness.clock,
            navigate: harness.navigation.navigate
        )
        model.focusChanged(true, revision: 0)
        model.scanner.focusGained()
        await model.container.readTask?.value
        let linking = Task { await model.link(Self.payload) }
        await labelsEventually("the question") { held.isAsking }
        #expect(model.phase.labelsName == "deciding")
        #expect(!model.isActive)
        #expect(!model.scanner.cameraRuns)
        #expect(model.panel == nil)
        held.answer(true)
        await linking.value
        #expect(harness.qr.bound.count == 1)
    }

    @Test("moving a sticker from another container names both; Move sticker links it here")
    func move() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(qrToken: ScanTestData.otherToken), confirm: [true])
        let shelf = Container(id: "c2", spaceId: "s1", name: "Shelf A", visualType: .shelf, shortCode: "SHL-4QW8", createdAt: 1, updatedAt: 1)
        harness.qr.answer(Self.payload, with: .success(.bound(container: shelf, token: ScanTestData.token)))
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(harness.confirm.asked == [ConfirmOptions(
            title: "Move this sticker to Tool chest?",
            body: "It opens Shelf A now. After this it opens Tool chest instead. Tool chest already has a label. Its old sticker will stop opening it.",
            confirmLabel: "Move sticker"
        )])
        #expect(harness.qr.bound.map(\.containerId) == ["c1"])
        #expect(harness.navigation.destinations == [.close])
        #expect(harness.toasts.messages == ["Sticker linked to Tool chest."])
    }

    @Test("Linking the sticker… while the link is written, with the camera off")
    func linkingPanel() async {
        let harness = LabelsLinkStickerHarness(holdBinds: true)
        let model = await harness.loaded()
        let linking = Task { await model.link(Self.payload) }
        await harness.qr.bindLatch?.waitForArrivals(1)
        #expect(model.phase.labelsName == "linking")
        #expect(!model.isActive)
        #expect(model.panel?.tone == .busy)
        #expect(model.panel?.message == "Linking the sticker…")
        await harness.qr.bindLatch?.release()
        await linking.value
        #expect(harness.navigation.destinations == [.close])
    }

    @Test("a failed lookup says what went wrong; Try again scans again without the old lookup")
    func lookupFailed() async {
        let harness = LabelsLinkStickerHarness()
        harness.qr.answer(Self.payload, with: .failure(LabelsTestData.offline))
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(model.phase.labelsName == "failed")
        #expect(harness.haptics.played == [.error])
        let words = describeError(LabelsTestData.offline, context: .read, subject: .container)
        #expect(model.panel?.title == words.title)
        #expect(model.panel?.message == words.body)
        #expect(model.panel?.action == .tryAgain)
        #expect(model.panel?.action?.identifier == "link-try-again")
        #expect(!model.isActive)

        model.perform(.tryAgain)
        #expect(model.phase.labelsName == "scanning")
        #expect(harness.qr.resolved == [Self.payload])
        #expect(model.isActive)
    }

    @Test("a failed link shows on the panel in read wording: nothing was linked")
    func bindFailed() async {
        let harness = LabelsLinkStickerHarness()
        harness.qr.bindError = LabelsTestData.ReadFailure()
        let model = await harness.loaded()
        await model.link(Self.payload)
        #expect(model.phase.labelsName == "failed")
        #expect(harness.haptics.played == [.error])
        #expect(model.panel?.message == describeError(LabelsTestData.ReadFailure(), context: .read, subject: .container).body)
        #expect(harness.toasts.messages.isEmpty)
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.telemetry.names.isEmpty)
        #expect(harness.invalidator.count == 0)
    }

    @Test("closing while the sticker is read writes nothing and says nothing")
    func closedWhileReading() async {
        let harness = LabelsLinkStickerHarness(holdResolves: true)
        let model = await harness.loaded()
        let linking = Task { await model.link(Self.payload) }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.resolveLatch?.release()
        await linking.value
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
        #expect(harness.navigation.destinations.isEmpty)
    }

    @Test("closing while a lookup fails says nothing")
    func closedWhileFailing() async {
        let harness = LabelsLinkStickerHarness(holdResolves: true)
        harness.qr.answer(Self.payload, with: .failure(LabelsTestData.offline))
        let model = await harness.loaded()
        let linking = Task { await model.link(Self.payload) }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.resolveLatch?.release()
        await linking.value
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
    }

    @Test("closing while it links: still linked and said, but nothing closes")
    func closedWhileLinking() async {
        let harness = LabelsLinkStickerHarness(holdBinds: true)
        let model = await harness.loaded()
        let linking = Task { await model.link(Self.payload) }
        await harness.qr.bindLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.bindLatch?.release()
        await linking.value
        #expect(harness.qr.bound.count == 1)
        #expect(harness.telemetry.names == ["qr_bound"])
        #expect(harness.haptics.played == [.success])
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.toasts.messages == ["Sticker linked to Tool chest."])
    }

    @Test("a link that fails after the camera closed is told in a toast")
    func failedAfterClosing() async {
        let harness = LabelsLinkStickerHarness(holdBinds: true)
        harness.qr.bindError = LabelsTestData.offline
        let model = await harness.loaded()
        let linking = Task { await model.link(Self.payload) }
        await harness.qr.bindLatch?.waitForArrivals(1)
        model.close()
        await harness.qr.bindLatch?.release()
        await linking.value
        #expect(harness.haptics.played == [.error])
        #expect(harness.toasts.messages == ["The sticker was not linked to Tool chest. Try again."])
        #expect(harness.toasts.last?.tone == .error)
        #expect(harness.navigation.destinations.isEmpty)
    }

    @Test("closing while the question is up goes back to scanning and writes nothing, even on yes")
    func closedWhileDeciding() async {
        let harness = LabelsLinkStickerHarness(container: LabelsTestData.container(qrToken: ScanTestData.otherToken))
        let held = LabelsHeldConfirm()
        let model = LinkStickerModel(
            containerId: "c1",
            permission: ScanTestData.permission(),
            read: { [containers = harness.containers] in try await containers.read($0) },
            qr: { [qr = harness.qr] in qr },
            invalidator: harness.invalidator,
            toasts: harness.toasts,
            confirm: held,
            haptics: harness.haptics.player,
            clock: harness.clock,
            navigate: harness.navigation.navigate
        )
        model.focusChanged(true, revision: 0)
        await model.container.readTask?.value
        let linking = Task { await model.link(Self.payload) }
        await labelsEventually("the question") { held.isAsking }
        model.close()
        held.answer(true)
        await linking.value
        #expect(model.phase.labelsName == "scanning")
        #expect(harness.qr.bound.isEmpty)
        #expect(harness.toasts.messages.isEmpty)
    }

    @Test("through the scanner: one sticker per arming, and Scan again accepts the same one")
    func throughTheScanner() async {
        let harness = LabelsLinkStickerHarness()
        let model = await harness.loaded()
        await model.scanner.codeDetected("not ours")
        await model.scanner.codeDetected("not ours")
        #expect(harness.qr.resolved == ["not ours"])
        #expect(model.phase.labelsName == "notOurs")
        await model.scanner.codeDetected("not ours")
        #expect(harness.qr.resolved == ["not ours"], "the camera is off under the notice")

        model.scanAgain()
        await model.scanner.codeDetected("not ours")
        #expect(harness.qr.resolved == ["not ours", "not ours"])
    }

    @Test("a sticker read before the container is known does nothing")
    func beforeTheContainer() async {
        let harness = LabelsLinkStickerHarness(holdContainer: true)
        let model = harness.model()
        model.focusChanged(true, revision: 0)
        await model.link(Self.payload)
        #expect(harness.qr.resolved.isEmpty)
        #expect(model.phase.labelsName == "scanning")
        await harness.containers.latch?.waitForArrivals(1)
        await harness.containers.latch?.release()
    }
}

/// A confirmation the test answers when it likes.
@MainActor
final class LabelsHeldConfirm: ConfirmPresenting {
    private var pending: CheckedContinuation<Bool, Never>?
    private(set) var asked: [ConfirmOptions] = []

    var isAsking: Bool { pending != nil }

    func confirm(_ options: ConfirmOptions) async -> Bool {
        asked.append(options)
        return await withCheckedContinuation { pending = $0 }
    }

    func answer(_ value: Bool) {
        pending?.resume(returning: value)
        pending = nil
    }
}

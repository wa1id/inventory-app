import Foundation
import InventoryCore
import InventoryServices
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The seams every places model takes, recorded.
@MainActor
struct PlacesSeams {
    let toasts = SharedSeamsToastRecorder()
    let haptics = SharedSeamsHapticRecorder()
    let invalidations = SharedSeamsInvalidationCounter()
    let telemetry = RecordingTelemetry()
    let photos = EntitiesPhotoSpy()
    let confirm: SharedSeamsConfirmScript

    init(confirmAnswers: [Bool] = []) {
        confirm = SharedSeamsConfirmScript(answers: confirmAnswers)
    }

    var reporter: TelemetryReporter { TelemetryReporter(sink: telemetry) }
}

/// An opener waiting for a screen's answer (the place picker), as `Router.presentForResult` waits.
@MainActor
final class PlacesOpener<Value: Sendable> {
    private(set) var request: RouteRequest<Value>?
    /// Nil until answered; `.some(nil)` when abandoned.
    private(set) var answer: Value??
    private var task: Task<Void, Never>?

    /// Opens a request on `results` and returns once it is pending.
    func open(_ results: RouteResults) async {
        task = Task { [self] in
            let value = try? await results.open(Value.self) { request = $0 }
            answer = .some(value ?? nil)
        }
        while request == nil { await Task.yield() }
    }

    /// Waits for the answer.
    func waitForAnswer() async {
        await task?.value
    }
}

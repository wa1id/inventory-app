import Synchronization
import Testing
@testable import InventoryCore

private final class RecordingSink: TelemetrySink {
    let events = Mutex<[(level: String, name: String, payload: TelemetryPayload)]>([])

    func event(_ name: String, _ payload: TelemetryPayload) {
        events.withLock { $0.append(("event", name, payload)) }
    }

    func error(_ name: String, _ payload: TelemetryPayload) {
        events.withLock { $0.append(("error", name, payload)) }
    }
}

// RN: src/services/ai/__tests__/recognition.test.ts "keeps only allowlisted measurement keys"
@Test func keepsOnlyAllowlistedMeasurementKeys() {
    let safe = Telemetry.redact([
        "latencyMs": .int(120),
        "outcome": .string("success"),
        "itemName": .string("Cordless Drill"),
        "imageUri": .string("file:///photo.jpg"),
        "token": .string("abc"),
    ])
    #expect(safe == ["latencyMs": .int(120), "outcome": .string("success")])
}

@Suite(.serialized) struct TelemetrySinkTests {
    @Test func routesRedactedEventsAndErrorsToTheSink() {
        let sink = RecordingSink()
        Telemetry.setSink(sink)
        defer { Telemetry.setSink(DebugLogSink()) }

        Telemetry.logEvent("search_performed", ["termCount": .int(2), "query": .string("drill")])
        Telemetry.logError("recognition_failed", ["statusCode": .int(500), "body": .string("x")])

        let events = sink.events.withLock { $0 }
        #expect(events.count == 2)
        #expect(events[0].level == "event" && events[0].name == "search_performed")
        #expect(events[0].payload == ["termCount": .int(2)])
        #expect(events[1].level == "error" && events[1].payload == ["statusCode": .int(500)])
    }
}

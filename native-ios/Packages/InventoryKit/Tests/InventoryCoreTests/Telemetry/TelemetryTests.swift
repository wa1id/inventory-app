import InventoryTestSupport
import Testing
@testable import InventoryCore

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
        let sink = RecordingTelemetry()
        Telemetry.setSink(sink)
        defer { Telemetry.setSink(DebugLogSink()) }

        Telemetry.logEvent("search_performed", ["termCount": .int(2), "query": .string("drill")])
        Telemetry.logError("recognition_failed", ["statusCode": .int(500), "body": .string("x")])

        // Only these two: another suite may log through the shared sink while it is swapped.
        let mine = sink.entries.filter { ["search_performed", "recognition_failed"].contains($0.name) }
        #expect(mine == [
            RecordingTelemetry.Entry(level: "event", name: "search_performed", payload: ["termCount": .int(2)]),
            RecordingTelemetry.Entry(level: "error", name: "recognition_failed", payload: ["statusCode": .int(500)]),
        ])
    }
}

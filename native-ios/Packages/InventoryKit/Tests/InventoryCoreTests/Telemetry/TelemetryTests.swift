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

@Suite("TelemetryReporter")
struct TelemetryReporterTests {
    @Test("an injected sink gets exactly what the process-wide one would: redacted, in order")
    func injectedSink() {
        let sink = RecordingTelemetry()
        let reporter = TelemetryReporter(sink: sink)
        reporter.event("item_created", ["hasPhoto": .bool(true), "name": .string("Cordless drill")])
        reporter.error("item_create_failed", ["errorClass": .string("offline"), "notes": .string("x")])
        reporter.event("item_moved")
        #expect(sink.entries == [
            RecordingTelemetry.Entry(level: "event", name: "item_created", payload: ["hasPhoto": .bool(true)]),
            RecordingTelemetry.Entry(level: "error", name: "item_create_failed", payload: ["errorClass": .string("offline")]),
            RecordingTelemetry.Entry(level: "event", name: "item_moved"),
        ])
    }
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

    @Test("the shared reporter is the process-wide sink")
    func sharedReporter() {
        let sink = RecordingTelemetry()
        Telemetry.setSink(sink)
        defer { Telemetry.setSink(DebugLogSink()) }

        TelemetryReporter.shared.event("household_left", ["itemName": .string("Drill")])
        TelemetryReporter.shared.error("restore_failed", ["durationMs": .int(4)])

        let mine = sink.entries.filter { ["household_left", "restore_failed"].contains($0.name) }
        #expect(mine == [
            RecordingTelemetry.Entry(level: "event", name: "household_left"),
            RecordingTelemetry.Entry(level: "error", name: "restore_failed", payload: ["durationMs": .int(4)]),
        ])
    }
}

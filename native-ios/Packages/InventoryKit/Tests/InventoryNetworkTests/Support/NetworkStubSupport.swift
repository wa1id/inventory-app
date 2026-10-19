import Foundation
import InventoryCore
import InventoryTestSupport
@testable import InventoryNetwork

// The network-specific glue around InventoryTestSupport's StubServer and RecordingTelemetry.

extension StubServer {
    /// The production ``URLSessionTransport`` over this server's session; it keeps the server alive.
    var transport: StubTransport { StubTransport(server: self, inner: URLSessionTransport(session: session)) }
}

/// ``URLSessionTransport`` plus a strong reference to its stub server, which a
/// client holding only the transport would otherwise let go mid-test.
struct StubTransport: HTTPTransport {
    let server: StubServer
    let inner: URLSessionTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await inner.send(request)
    }
}

/// A client-side transport that never touches the network, for failures URLSession cannot stage.
struct ThrowingTransport: HTTPTransport {
    let error: any Error & Sendable

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw error
    }
}

extension RecordingTelemetry {
    /// The clients' telemetry seam, recording what the process-wide sink would see:
    /// InventoryCore's redaction applied, as `NetworkTelemetry.standard` applies it.
    var telemetry: NetworkTelemetry {
        NetworkTelemetry(
            event: { [self] name, payload in event(name, Telemetry.redact(payload)) },
            error: { [self] name, payload in error(name, Telemetry.redact(payload)) }
        )
    }
}

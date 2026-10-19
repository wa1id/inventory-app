import Foundation
import InventoryCore

/// Asks our recognition endpoint (`POST /api/recognize`, server/) to identify an
/// item from its stored photo (RN: src/services/ai/recognition.ts).
///
/// Never throws: an unconfigured build, no connection, a timeout, a rate limit,
/// a malformed body and a weak guess all come back as `.failed`, so the caller
/// always lands in the editable state. Only timings and outcome classes are
/// logged; the image, the suggestion and anything typed stay on the phone.
public struct RecognitionClient: Sendable {
    /// RN `EXPO_PUBLIC_RECOGNITION_TIMEOUT_MS` default.
    public static let defaultTimeout: Duration = .milliseconds(15_000)

    /// The full endpoint URL, path included; nil or empty means not configured.
    public let endpoint: String?
    private let key: String?
    public let timeout: Duration
    private let transport: any HTTPTransport
    private let clock: any Clock<Duration>
    private let readImage: @Sendable (URL) async throws -> Data
    private let telemetry: NetworkTelemetry

    /// - Parameters:
    ///   - key: the public app key sent as `x-inventory-key`; omitted when nil or empty.
    ///   - readImage: reads the stored photo; it runs inside the deadline, as RN's file read did.
    public init(
        endpoint: String?,
        key: String?,
        timeout: Duration = RecognitionClient.defaultTimeout,
        transport: any HTTPTransport = URLSessionTransport.shared,
        clock: any Clock<Duration> = ContinuousClock(),
        readImage: @escaping @Sendable (URL) async throws -> Data = { try Data(contentsOf: $0) },
        telemetry: NetworkTelemetry = .standard
    ) {
        self.endpoint = endpoint
        self.key = key
        self.timeout = timeout
        self.transport = transport
        self.clock = clock
        self.readImage = readImage
        self.telemetry = telemetry
    }

    /// Whether a request would be made at all (Settings "Photo suggestions").
    public var isConfigured: Bool { !(endpoint ?? "").isEmpty }

    /// Recognises the photo at `imageURL`, a resolved local file.
    ///
    /// - Parameter nameHint: a name the user typed over the suggestion; the server
    ///   re-derives the other fields for it. Blank means no hint, and the key is
    ///   then left out of the body entirely.
    public func recognize(imageAt imageURL: URL, nameHint: String? = nil) async -> RecognitionResult {
        guard let endpoint, !endpoint.isEmpty else {
            telemetry.event("recognition_skipped", ["outcome": .string(RecognitionFailureReason.notConfigured.rawValue)])
            return .failed(.notConfigured)
        }

        let trimmedHint = nameHint?.jsTrimmed()
        let hint = trimmedHint?.isEmpty == false ? trimmedHint : nil
        let hinted = hint != nil
        let startedAt = ContinuousClock.now
        func latencyMs() -> TelemetryValue { .int(elapsedMilliseconds(since: startedAt)) }

        do {
            // The deadline starts before the file read, as RN's timer did.
            let response = try await withTotalTimeout(timeout, clock: clock) { [self] in
                let bytes = try await readImage(imageURL)
                return try await transport.send(try makeRequest(endpoint: endpoint, image: bytes, hint: hint))
            }

            guard response.isSuccess else {
                let reason: RecognitionFailureReason = response.status == 429 ? .rateLimited : .serverError
                telemetry.error("recognition_failed", [
                    "outcome": .string(reason.rawValue),
                    "statusCode": .int(response.status),
                    "latencyMs": latencyMs(),
                    "contractVersion": .int(recognitionContractVersion),
                    "hinted": .bool(hinted),
                ])
                return .failed(reason)
            }

            guard let body = WireJSON.parse(response.body) else {
                telemetry.error("recognition_failed", [
                    "outcome": .string(RecognitionFailureReason.malformedResponse.rawValue),
                    "latencyMs": latencyMs(),
                    "contractVersion": .int(recognitionContractVersion),
                    "hinted": .bool(hinted),
                ])
                return .failed(.malformedResponse)
            }

            let result = parseRecognitionResponse(body)
            let confidence: TelemetryValue = if case .success(let suggestion, _) = result {
                .double(suggestion.confidence)
            } else {
                .null
            }
            telemetry.event("recognition_completed", [
                "outcome": .string(result.outcome),
                "latencyMs": latencyMs(),
                "contractVersion": .int(recognitionContractVersion),
                "confidence": confidence,
                "hinted": .bool(hinted),
            ])
            return result
        } catch {
            let reason: RecognitionFailureReason = switch TransportFailure.classify(error) {
            case .deadline: .timeout
            case .offline: .offline
            case .cancelled, .other: .serverError
            }
            telemetry.error("recognition_failed", [
                "outcome": .string(reason.rawValue),
                "latencyMs": latencyMs(),
                "contractVersion": .int(recognitionContractVersion),
                "hinted": .bool(hinted),
            ])
            return .failed(reason)
        }
    }

    /// `POST <endpoint>` with the v1 body (05 §10.2). Never `Authorization` or `x-api-key`.
    func makeRequest(endpoint: String, image: Data, hint: String?) throws -> URLRequest {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, method: "POST", deadline: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(recognitionContractVersion), forHTTPHeaderField: "X-Contract-Version")
        if let key, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-inventory-key")
        }
        let body = RecognitionRequestBody(
            image: .init(data: image.base64EncodedString(), mediaType: ImageMediaType.sniff(image)),
            nameHint: hint
        )
        request.httpBody = try wireJSONEncoder().encode(body)
        return request
    }

}

extension RecognitionClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Leaves the app key out of `print`, `dump` and string interpolation: it ships in
    /// the bundle, but the build keeps it out of logs (DECISIONS U1), as SyncClient does.
    public var description: String { "RecognitionClient(endpoint: \(endpoint ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["endpoint": endpoint as Any, "timeout": timeout], displayStyle: .struct)
    }
}

/// The v1 request body. `nameHint` is omitted entirely when absent, so an unhinted
/// request stays byte-compatible with every deployed backend.
struct RecognitionRequestBody: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        let data: String
        let encoding = "base64"
        let mediaType: String

        init(data: String, mediaType: String) {
            self.data = data
            self.mediaType = mediaType
        }
    }

    let contractVersion = recognitionContractVersion
    let image: Image
    let nameHint: String?

    init(image: Image, nameHint: String?) {
        self.image = image
        self.nameHint = nameHint
    }
}

// RN: src/repositories/qr.ts:29-46. The printed QR payload. Shared by the local
// and household repositories, the Scan screen and deep links.

/// URL form printed into a QR code; the app's own scheme, so the system camera deep-links into the app.
public let qrURIPrefix = "inventory://c/"

/// `inventory://c/<token>` (RN `formatQrPayload`).
public func formatQrPayload(_ token: String) -> String {
    qrURIPrefix + token
}

/// Our token from a scanned string, lowercased, or `nil` when the code is not ours (RN `parseQrPayload`).
///
/// Accepts the deep-link form and a bare token; the rest must be exactly 32 ASCII
/// hex digits. The prefix match is case-sensitive.
public func parseQrPayload(_ raw: String) -> String? {
    let value = raw.jsTrimmed()
    let candidate = value.hasPrefixScalars(qrURIPrefix)
        ? String(value.unicodeScalars.dropFirst(qrURIPrefix.unicodeScalars.count))
        : value
    let scalars = candidate.unicodeScalars
    guard scalars.count == 32, scalars.allSatisfy(\.isASCIIHexDigit) else { return nil }
    return candidate.lowercased()
}

extension String {
    /// Code-point prefix test, like JS `startsWith` (Swift `hasPrefix` compares Characters).
    func hasPrefixScalars(_ prefix: String) -> Bool {
        unicodeScalars.starts(with: prefix.unicodeScalars)
    }
}

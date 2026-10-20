import Foundation

/// A link the app opens (06 §3.6, DECISIONS U5): only the QR label, `inventory://c/<token>`.
///
/// Printed labels encode `inventory://c/<token>` (RN src/repositories/qr.ts:23-33), so the system
/// Camera opens the app on that label. Both registered schemes are accepted, `inventory` and the
/// Expo-added `com.wystudio.inventory` (02 §9.4), with the token in either place expo-router
/// matched it:
/// - `inventory://c/<token>`: host `c`, the token as the only path segment;
/// - `inventory:///c/<token>`: no host, path `c/<token>`.
///
/// The token is the path segment, percent-decoded; a repeated `token` query parameter comes after
/// it, and `ScanRules.tokenParam` keeps the first and trims it (RN `tokenParam`). A blank token
/// still opens the label screen, which then says it is not one of our labels (RN routed it the
/// same way). Every other path (`inventory://item/<id>`, `inventory://c/<token>/extra`,
/// `inventory://c/`) is ignored: expo-router showed its "Unmatched route" screen for those, and the
/// native app never produced them (06 Q4).
public enum DeepLink: Sendable, Hashable {
    /// `/c/<token>`, already through `ScanRules.tokenParam`.
    case label(token: String)

    /// The URL schemes in `CFBundleURLTypes`.
    public static let schemes: Set<String> = ["inventory", "com.wystudio.inventory"]

    /// The link `url` asks for, or nil when the app does not open it.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // Path segments, percent-decoded; the leading "/" and a trailing slash are not segments.
        let segments = url.pathComponents.filter { $0 != "/" }
        let host = (components.host ?? "").lowercased()

        let pathToken: String
        if host == "c" {
            guard segments.count == 1 else { return nil }
            pathToken = segments[0]
        } else if host.isEmpty {
            guard segments.count == 2, segments[0] == "c" else { return nil }
            pathToken = segments[1]
        } else {
            return nil
        }

        let repeated = (components.queryItems ?? []).filter { $0.name == "token" }.compactMap(\.value)
        self = .label(token: ScanRules.tokenParam([pathToken] + repeated))
    }
}

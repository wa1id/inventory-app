import Foundation

/// The media type of encoded image bytes, read from their magic numbers.
///
/// RN declared `image/jpeg` for every photo, though captures have been WebP
/// for a while; Anthropic rejects bytes that disagree with the declared type,
/// so recognition answered 502 for every photo (05 C2). DECISIONS U6: send the
/// real type. The sync upload uses the same sniffing for its `Content-Type`
/// (03 B5, Q3), which the Worker allowlists.
public enum ImageMediaType {
    /// What RN always sent, and the type assumed when the bytes are not recognised.
    public static let fallback = "image/jpeg"

    /// `image/webp`, `image/jpeg`, `image/png` or `image/gif`; ``fallback`` otherwise.
    public static func sniff(_ data: Data) -> String {
        let head = Array(data.prefix(12))
        if head.count >= 12, head[0..<4].elementsEqual(Array("RIFF".utf8)), head[8..<12].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        return fallback
    }
}

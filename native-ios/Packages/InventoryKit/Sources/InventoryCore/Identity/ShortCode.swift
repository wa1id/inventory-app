// RN: src/core/shortCode.ts. Human-friendly container codes such as `BOX-7K2M`.
// Uniqueness is enforced by `UNIQUE(short_code)`; `containers.create` retries.

/// Suffix alphabet: no `0`, `1`, `I` or `O`, so a handwritten or spoken code stays readable.
let shortCodeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

/// Number of random characters after the prefix.
let shortCodeSuffixLength = 4

extension ContainerVisualType {
    /// The short-code prefix for this type; unknown types use `CTR`, like `other`.
    public var shortCodePrefix: String {
        switch self {
        case .box: "BOX"
        case .drawer: "DRW"
        case .shelf: "SHF"
        case .cabinet: "CAB"
        case .bin: "BIN"
        case .bag: "BAG"
        case .crate: "CRT"
        default: "CTR"
        }
    }
}

/// `PREFIX-XXXX` with a random four-character suffix from the unambiguous alphabet (RN `generateShortCode`).
public func generateShortCode(
    _ visualType: ContainerVisualType,
    using generator: inout some RandomNumberGenerator
) -> String {
    var suffix = ""
    for _ in 0..<shortCodeSuffixLength {
        suffix.append(shortCodeAlphabet[Int.random(in: 0..<shortCodeAlphabet.count, using: &generator)])
    }
    return "\(visualType.shortCodePrefix)-\(suffix)"
}

/// `PREFIX-XXXX` from the system random generator (RN `generateShortCode`).
public func generateShortCode(_ visualType: ContainerVisualType) -> String {
    var generator = SystemRandomNumberGenerator()
    return generateShortCode(visualType, using: &generator)
}

/// Trim, upper-case (JS rules) and remove whitespace and dashes: `box-7k2m` → `BOX7K2M` (RN `normalizeShortCode`).
public func normalizeShortCode(_ input: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in input.jsTrimmed().jsUppercased().unicodeScalars where !scalar.isJSWhitespace && scalar != "-" {
        out.append(scalar)
    }
    return String(out)
}

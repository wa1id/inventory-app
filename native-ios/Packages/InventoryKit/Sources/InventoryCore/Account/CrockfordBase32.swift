// RN: src/services/account/base32.ts, byte-compatible with worker/src/base32.ts
// (and home-server/src/base32.ts). The recovery code and the household code are
// Crockford base32: no I, L, O or U, so the usual misreads cannot make a
// different valid code. Changing this strands every backup behind a code that
// no longer decodes.

/// Crockford base32 as the sync Worker and the home server implement it.
public enum CrockfordBase32 {
    /// `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (32 symbols; no I, L, O, U).
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".unicodeScalars)

    /// Symbol values, including the folds `I`→1, `L`→1, `O`→0.
    private static let decodeMap: [Unicode.Scalar: UInt32] = {
        var map: [Unicode.Scalar: UInt32] = [:]
        for (index, scalar) in alphabet.enumerated() {
            map[scalar] = UInt32(index)
        }
        map["I"] = 1
        map["L"] = 1
        map["O"] = 0
        return map
    }()

    /// MSB-first, no padding; a partial last group is left-aligned (RN `encodeBase32`).
    ///
    /// 16 bytes always give 26 characters.
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var out = String.UnicodeScalarView()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = ((buffer << 8) | UInt32(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return String(out)
    }

    /// The bytes of a code, or `nil` for anything malformed (RN `decodeBase32`).
    ///
    /// Removes every `-`, trims (JS rules), upper-cases (JS rules); an empty
    /// result is `nil`. Any character outside the alphabet and its folds,
    /// including inner whitespace, is `nil`. Leftover bits are dropped, so `n`
    /// valid characters give `floor(5n / 8)` bytes: one character gives `[]`,
    /// and both 26 and 27 characters give 16 bytes. Length checks are the caller's.
    public static func decode(_ value: String) -> [UInt8]? {
        var withoutDashes = String.UnicodeScalarView()
        withoutDashes.append(contentsOf: value.unicodeScalars.lazy.filter { $0 != "-" })
        let normalized = String(withoutDashes).jsTrimmed().jsUppercased()
        if normalized.isEmpty { return nil }

        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for scalar in normalized.unicodeScalars {
            guard let digit = decodeMap[scalar] else { return nil }
            buffer = ((buffer << 5) | digit) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return out
    }
}

/// The recovery code: 16 secret bytes shown as 26 Crockford base32 characters (03 §3).
public enum RecoveryCode {
    /// Secret size in bytes (RN `SECRET_BYTES`).
    public static let secretByteCount = 16
    /// Length of an unformatted code (RN `RECOVERY_CODE_LENGTH`).
    public static let length = 26

    /// Groups of five joined by `-`: `89144-GJ289-144GJ-28914-4GJ28-8` (RN `formatRecoveryCode`).
    public static func format(_ code: String) -> String {
        groupedInFives(code)
    }

    /// The 16-byte secret a typed code stands for, or `nil` when it does not decode to exactly 16 bytes.
    ///
    /// The forgiving half of RN `importAccount`: case, hyphens, surrounding
    /// whitespace and the I/L/1 and O/0 look-alikes are all accepted.
    public static func secret(from typed: String) -> [UInt8]? {
        guard let bytes = CrockfordBase32.decode(typed), bytes.count == secretByteCount else { return nil }
        return bytes
    }

    /// The canonical code for a typed one (what `importAccount` stores), or `nil` when malformed.
    public static func canonical(_ typed: String) -> String? {
        secret(from: typed).map(CrockfordBase32.encode)
    }
}

/// JS `(s.match(/.{1,5}/g) ?? []).join('-')`: groups of up to five characters.
///
/// A JS `.` does not match line terminators, so they are dropped and end a
/// group. Groups count code points; JS counts UTF-16 units, which only differs
/// for astral characters, never part of a valid code.
func groupedInFives(_ text: String) -> String {
    var groups: [String.UnicodeScalarView] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar.isJSLineTerminator {
            if !current.isEmpty { groups.append(current) }
            current = String.UnicodeScalarView()
            continue
        }
        current.append(scalar)
        if current.count == 5 {
            groups.append(current)
            current = String.UnicodeScalarView()
        }
    }
    if !current.isEmpty { groups.append(current) }
    return groups.map { String($0) }.joined(separator: "-")
}

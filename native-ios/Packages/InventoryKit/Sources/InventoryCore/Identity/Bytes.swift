// RN: src/core/bytes.ts. Hex encoding shared by ids, QR tokens and account ids,
// where a subtly different encoding only shows up as "the server does not
// recognise this device".

private let hexDigits = Array("0123456789abcdef".unicodeScalars)

/// Lowercase hex, two digits per byte (RN `toHex`).
public func toHex(_ bytes: some Sequence<UInt8>) -> String {
    var out = String.UnicodeScalarView()
    for byte in bytes {
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
    }
    return String(out)
}

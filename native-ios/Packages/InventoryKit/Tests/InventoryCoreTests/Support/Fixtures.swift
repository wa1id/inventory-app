import Foundation
import Testing

/// Loads a JSON parity-vector file generated from the TypeScript (see `Fixtures/generator/`).
func loadFixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json"
    )
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// Exact code-point equality. Swift `==` on strings uses canonical equivalence, which is too lenient for parity.
func sameScalars(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

func sameScalars(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { sameScalars($0, $1) }
}

/// `"U+0041 U+0301"`, for readable failure messages.
func scalarDump(_ value: String) -> String {
    value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
}

func scalarDump(_ values: [String]) -> String {
    "[" + values.map(scalarDump).joined(separator: ", ") + "]"
}

/// Bytes from lowercase hex.
func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return out
}

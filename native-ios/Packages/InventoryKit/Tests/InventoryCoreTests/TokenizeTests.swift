import Testing
@testable import InventoryCore

// Port of src/core/__tests__/tokenize.test.ts, plus the folding vectors of
// 01-data.md §6.6 and the generated corpus in Fixtures/folding.json.

@Suite("tokenizeQuery")
struct TokenizeQueryTests {
    @Test("lowercases and splits on whitespace")
    func lowercasesAndSplitsOnWhitespace() {
        #expect(tokenizeQuery("Cordless Drill") == ["cordless", "drill"])
    }

    @Test("returns nothing for empty or whitespace-only input")
    func returnsNothingForEmptyOrWhitespaceOnlyInput() {
        #expect(tokenizeQuery("") == [])
        #expect(tokenizeQuery("   ") == [])
        #expect(tokenizeQuery("!!! ??? ...") == [])
    }

    @Test("deduplicates repeated terms")
    func deduplicatesRepeatedTerms() {
        #expect(tokenizeQuery("drill drill DRILL") == ["drill"])
    }

    @Test("keeps dashes inside short codes but trims leading/trailing ones")
    func keepsDashesInsideShortCodes() {
        #expect(tokenizeQuery("BOX-7K2M") == ["box-7k2m"])
        #expect(tokenizeQuery("-drill-") == ["drill"])
    }

    @Test("splits on punctuation that is not a dash")
    func splitsOnPunctuationThatIsNotADash() {
        #expect(tokenizeQuery("screws, nails; bolts") == ["screws", "nails", "bolts"])
    }

    @Test("strips accents so unaccented queries still match")
    func stripsAccents() {
        #expect(tokenizeQuery("Café") == ["cafe"])
    }

    @Test("keeps digits and non-latin scripts")
    func keepsDigitsAndNonLatinScripts() {
        #expect(tokenizeQuery("18v battery") == ["18v", "battery"])
        #expect(sameScalars(tokenizeQuery("ワイヤー"), ["ワイヤー"]))
    }

    @Test("caps the number of terms")
    func capsTheNumberOfTerms() {
        let query = (0..<40).map { "term\($0)" }.joined(separator: " ")
        #expect(tokenizeQuery(query).count == 12)
        #expect(tokenizeQuery(query) == (0..<12).map { "term\($0)" })
    }
}

@Suite("toLikePattern")
struct ToLikePatternTests {
    @Test("wraps a term in wildcards")
    func wrapsATermInWildcards() {
        #expect(toLikePattern("drill") == "%drill%")
    }

    @Test("escapes LIKE wildcards so they match literally")
    func escapesLikeWildcards() {
        #expect(toLikePattern("50%") == "%50\\%%")
        #expect(toLikePattern("a_b") == "%a\\_b%")
        #expect(toLikePattern("a\\b") == "%a\\\\b%")
    }
}

@Suite("short codes")
struct ShortCodeTests {
    @Test("uses an unambiguous alphabet")
    func usesAnUnambiguousAlphabet() throws {
        let pattern = try Regex("^BOX-[2-9A-HJ-NP-Z]{4}$")
        for _ in 0..<200 {
            let code = generateShortCode(.box)
            #expect(code.wholeMatch(of: pattern) != nil, "\(code)")
            // O/0 and I/1 are excluded because codes get handwritten on labels.
            #expect(!code.dropFirst(4).contains { "OI01".contains($0) })
        }
    }

    @Test("compares codes ignoring case and dashes")
    func comparesCodesIgnoringCaseAndDashes() {
        #expect(normalizeShortCode("box-7k2m") == "BOX7K2M")
        #expect(normalizeForCodeMatch("BOX-7K2M") == "box7k2m")
    }

    @Test("uses the prefix of each visual type, CTR for unknown ones")
    func usesThePrefixOfEachVisualType() throws {
        struct Entry: Decodable { let type: String; let prefix: String }
        struct File: Decodable { let prefixes: [Entry] }
        for entry in try loadFixture("codes", as: File.self).prefixes {
            #expect(ContainerVisualType(entry.type).shortCodePrefix == entry.prefix, "\(entry.type)")
            #expect(generateShortCode(ContainerVisualType(entry.type)).hasPrefix(entry.prefix + "-"))
        }
    }

    @Test("draws the suffix from the injected generator")
    func drawsTheSuffixFromTheInjectedGenerator() {
        struct Fixed: RandomNumberGenerator {
            var value: UInt64
            mutating func next() -> UInt64 { value }
        }
        var zero = Fixed(value: 0)
        #expect(generateShortCode(.drawer, using: &zero) == "DRW-2222")
        var max = Fixed(value: .max)
        #expect(generateShortCode("Box", using: &max) == "CTR-ZZZZ")
    }
}

@Suite("compactAlphanumeric")
struct CompactAlphanumericTests {
    @Test("folds USB-C style punctuation so typed usbc still matches")
    func foldsUSBCStylePunctuation() {
        #expect(compactAlphanumeric("USB-C") == "usbc")
        #expect(compactAlphanumeric("usb c") == "usbc")
        #expect(compactAlphanumeric("usb/c") == "usbc")
        #expect(compactAlphanumeric("usbc") == "usbc")
    }
}

// 01-data.md §6.6, verified in Node.
@Suite("folding vectors (01 §6.6)")
struct FoldingVectorTests {
    static let tokenVectors: [(String, [String])] = [
        ("Cordless Drill", ["cordless", "drill"]),
        ("BOX-7K2M", ["box-7k2m"]),
        ("-drill-", ["drill"]),
        ("a--b- --c", ["a--b", "c"]),
        ("Café", ["cafe"]),
        ("ワイヤー", ["ワイヤー"]),
        ("ガラス", ["\u{30AB}", "ラス"]),
        ("ﬁle Ⅻ ①", ["file", "xii", "1"]),
        ("ΟΔΟΣ", ["οδο\u{03C2}"]),
        ("İstanbul", ["istanbul"]),
        ("emoji 🔧x", ["emoji", "x"]),
        ("under_score", ["under", "score"]),
        ("o'neil", ["o", "neil"]),
        ("Straße", ["straße"]),
        ("™ 𝐀BC ℌ ㎒ Ｆｕｌｌ", ["TM", "Abc", "H", "MHz", "full"]),
        ("\u{01C5}", ["dz"]),
        ("ΣΑΣ Σ", ["σα\u{03C2}", "\u{03C3}"]),
        ("aΣ.", ["a\u{03C2}"]),
    ]

    @Test("tokenizeQuery", arguments: tokenVectors)
    func tokenize(input: String, expected: [String]) {
        let actual = tokenizeQuery(input)
        #expect(sameScalars(actual, expected), "\(input): \(scalarDump(actual)) != \(scalarDump(expected))")
    }

    static let compactVectors: [(String, String)] = [
        ("BOX-7K2M", "box7k2m"),
        ("Café", "cafe"),
        ("ガラス", "\u{30AB}ラス"),
        ("™ 𝐀BC ℌ ㎒ Ｆｕｌｌ", "TMAbcHMHzfull"),
        ("\u{01C5}", "dz"),
        ("USB-C", "usbc"),
        ("usb c", "usbc"),
        ("usb/c", "usbc"),
        ("Küche", "kuche"),
        ("Кухня", "кухня"),
    ]

    @Test("compactAlphanumeric", arguments: compactVectors)
    func compact(input: String, expected: String) {
        let actual = compactAlphanumeric(input)
        #expect(sameScalars(actual, expected), "\(input): \(scalarDump(actual))")
    }

    @Test("toLikePattern escapes a backslash")
    func likeEscapesBackslash() {
        #expect(toLikePattern("a\\b") == "%a\\\\b%")
    }

    // 01 §13.8 #11: NFKD runs after lowercasing, so capitals survive.
    @Test("tokenizer order keeps NFKD capitals")
    func tokenizerOrderKeepsNFKDCapitals() {
        #expect(tokenizeQuery("™ 𝐀BC ℌ ㎒") == ["TM", "Abc", "H", "MHz"])
    }
}

/// One entry of Fixtures/folding.json.
struct FoldingEntry: Decodable {
    let input: String
    let lower: String
    let upper: String
    let trim: String
    let tokens: [String]
    let compact: String
    let placeTerms: [String]
    let like: String
    let normalizeShortCode: String
    let normaliseCode: String
    let invalidCodeChars: [String]
    let spellCode: String
    let qr: String?
}

@Suite("folding parity corpus (Fixtures/folding.json)")
struct FoldingCorpusTests {
    let entries: [FoldingEntry]

    init() throws {
        entries = try loadFixture("folding")
    }

    @Test("the corpus is non-trivial")
    func corpusIsLoaded() {
        #expect(entries.count > 600)
    }

    @Test("tokenizeQuery matches JS")
    func tokenizeMatchesJS() {
        for entry in entries {
            let actual = tokenizeQuery(entry.input)
            #expect(
                sameScalars(actual, entry.tokens),
                "\(scalarDump(entry.input)): \(scalarDump(actual)) != \(scalarDump(entry.tokens))"
            )
        }
    }

    @Test("compactAlphanumeric matches JS")
    func compactMatchesJS() {
        for entry in entries {
            let actual = compactAlphanumeric(entry.input)
            #expect(sameScalars(actual, entry.compact), "\(scalarDump(entry.input)): \(scalarDump(actual))")
        }
    }

    @Test("toLikePattern matches JS")
    func likeMatchesJS() {
        for entry in entries {
            #expect(sameScalars(toLikePattern(entry.input), entry.like), "\(scalarDump(entry.input))")
        }
    }

    @Test("normalizeShortCode matches JS")
    func normalizeShortCodeMatchesJS() {
        for entry in entries {
            let actual = normalizeShortCode(entry.input)
            #expect(sameScalars(actual, entry.normalizeShortCode), "\(scalarDump(entry.input)): \(scalarDump(actual))")
        }
    }
}

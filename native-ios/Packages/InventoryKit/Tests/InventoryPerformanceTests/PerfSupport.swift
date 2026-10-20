import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

// Shared by the performance suites (docs/PERFORMANCE.md).
//
// Timings that guard regressions use the CPU time of the thread that ran the SQL, measured
// inside the database closure: a test process that is starved for seconds (Swift Testing runs
// two thousand tests at once on a Mac that also builds six other checkouts) does not add to
// it, where wall-clock time would. Each figure is the best of a few runs, and the limits leave
// a wide margin over what a quiet Mac measures.

/// The CPU time this thread has used.
func perfThreadCPUTime() -> Duration {
    .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
}

/// One run's wall-clock and CPU time.
struct PerfSample: Sendable, Comparable {
    var wall: Duration
    var cpu: Duration

    static func < (lhs: PerfSample, rhs: PerfSample) -> Bool { lhs.cpu < rhs.cpu }

    /// `12.3 ms`.
    static func text(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration.perfMilliseconds)
    }
}

extension Duration {
    /// In milliseconds, fractions kept.
    var perfMilliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// Several runs of the same work, fastest and median by CPU time.
struct PerfMeasurement: Sendable {
    var samples: [PerfSample]

    var best: PerfSample { samples.min() ?? PerfSample(wall: .zero, cpu: .zero) }
    var median: PerfSample {
        let sorted = samples.sorted()
        return sorted.isEmpty ? PerfSample(wall: .zero, cpu: .zero) : sorted[sorted.count / 2]
    }
}

/// Runs `body` `repeats` times inside a read of `store`, timing each run on the thread that ran it.
func perfMeasureRead<T>(
    _ store: DatabaseStore,
    repeats: Int = 5,
    _ body: (Database) throws -> T
) throws -> (PerfMeasurement, T) {
    var samples: [PerfSample] = []
    var last: T?
    for _ in 0..<max(1, repeats) {
        let (sample, value) = try store.queue.read { db -> (PerfSample, T) in
            let wallStart = ContinuousClock.now
            let cpuStart = perfThreadCPUTime()
            let value = try body(db)
            return (PerfSample(wall: ContinuousClock.now - wallStart, cpu: perfThreadCPUTime() - cpuStart), value)
        }
        samples.append(sample)
        last = value
    }
    // `repeats` is at least one, so the loop ran.
    return (PerfMeasurement(samples: samples), last!)
}

/// Runs `body` `repeats` times on this thread, timing each run.
func perfMeasure(repeats: Int = 5, _ body: () throws -> Void) rethrows -> PerfMeasurement {
    var samples: [PerfSample] = []
    for _ in 0..<max(1, repeats) {
        let wallStart = ContinuousClock.now
        let cpuStart = perfThreadCPUTime()
        try body()
        samples.append(PerfSample(wall: ContinuousClock.now - wallStart, cpu: perfThreadCPUTime() - cpuStart))
    }
    return PerfMeasurement(samples: samples)
}

/// Misspelt searches and vocabularies for measuring ``SearchSpelling`` (docs/PERFORMANCE.md).
enum PerfSpelling {
    /// A misspelt word, two misspelt words, and a word nothing is close to (every word compared).
    static let queries = ["scrwdriver", "jumpr cabels", "zzqxv"]

    /// `words` distinct pronounceable words of 3 to 12 letters, the same every time: far more
    /// distinct words than the seed's word lists give, as a real 10 000-item inventory might.
    static func syntheticVocabulary(words: Int) -> SearchVocabulary {
        let consonants = Array("bcdfghjklmnprstvwz"), vowels = Array("aeiou")
        var state: UInt64 = 0x5EED_5BE1_1000_0001
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var counts: [String: Int] = [:]
        while counts.count < words {
            let length = 3 + next(10)
            let word = String((0..<length).map { $0 % 2 == 0 ? consonants[next(consonants.count)] : vowels[next(vowels.count)] })
            counts[word, default: 0] += 1 + next(20)
        }
        return SearchVocabulary(counts: counts)
    }
}

/// A file-backed database with ``PerfInventorySeed`` written into it, built once per shape.
final class PerfDatabase: Sendable {
    let store: DatabaseStore
    let repositories: LocalRepositories
    let summary: PerfInventorySeed.Summary
    /// Writing the seed, in one transaction.
    let seedTime: PerfSample

    init(shape: PerfInventorySeed.Shape, photos: Int = 320) throws {
        store = try DatabaseStore.temporary()
        try store.migrate()
        repositories = LocalRepositories(store: store)
        let wallStart = ContinuousClock.now
        let cpuStart = perfThreadCPUTime()
        summary = try store.queue.write { db in
            try PerfInventorySeed.write(
                shape, photos: PerfInventorySeed.placeholderPhotos(count: photos), now: 1_790_000_000_000, in: db)
        }
        seedTime = PerfSample(wall: ContinuousClock.now - wallStart, cpu: perfThreadCPUTime() - cpuStart)
    }

    /// The M9 inventory: 10 000 items.
    static let large = Result { try PerfDatabase(shape: .large) }
    /// A quarter of it, for checking that costs grow linearly.
    static let quarter = Result { try PerfDatabase(shape: .scaled(items: 2_500), photos: 80) }
}

/// The query classes measured on Home's search (docs/PERFORMANCE.md).
enum PerfQuery: String, CaseIterable, Sendable {
    case oneLetter = "a"
    case twoLetters = "sc"
    case commonWord = "screws"
    case containerType = "box"
    case spaceName = "garage"
    case accented = "crème"
    case accentedName = "zoë"
    case rareTwoWords = "jumper cables"
    case nothing = "zzqx"
    case shortCode = "BOX-7K"
    case threeWords = "red screws 4x40"
    case rnPerfTest = "widget 4242"

    var label: String {
        switch self {
        case .oneLetter: "1 letter"
        case .twoLetters: "2 letters"
        case .commonWord: "common word"
        case .containerType: "container type"
        case .spaceName: "space name"
        case .accented: "accented"
        case .accentedName: "accented name"
        case .rareTwoWords: "rare, 2 words"
        case .nothing: "no match"
        case .shortCode: "short code"
        case .threeWords: "3 words"
        case .rnPerfTest: "RN perf test"
        }
    }
}

/// Measure-only output, enabled with `INVENTORY_PERF=1` (docs/PERFORMANCE.md).
enum PerfReport {
    static let enabled = ProcessInfo.processInfo.environment["INVENTORY_PERF"] != nil

    static func line(_ text: String) {
        print("PERF | \(text)")
    }
}

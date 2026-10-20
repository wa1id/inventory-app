import Foundation
@testable import Inventory

/// Waits on the main actor until `condition` holds, letting queued tasks and camera hops run;
/// false after `timeout`.
@MainActor
func mediaWait(timeout: Duration = .seconds(3), until condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A fresh temporary directory, removed by the caller.
func mediaTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "media-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

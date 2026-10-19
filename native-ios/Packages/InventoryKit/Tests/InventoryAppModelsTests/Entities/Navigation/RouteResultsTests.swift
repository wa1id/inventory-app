import Foundation
import Testing
@testable import InventoryAppModels

/// `src/ui/__tests__/routeResult.test.ts`.
@MainActor
@Suite("routeResult (routeResult.test.ts)")
struct EntitiesRouteResultsTests {
    /// Holds the request `open` was given.
    @MainActor
    final class RequestBox<Value: Sendable> {
        var request: RouteRequest<Value>?
    }

    /// Opens a request and waits until it is registered, as RN's synchronous `open` does.
    private func open<Value: Sendable>(_ routes: RouteResults, _ type: Value.Type) async -> (RequestBox<Value>, Task<Value?, any Error>) {
        let box = RequestBox<Value>()
        let task = Task { try await routes.open(Value.self) { box.request = $0 } }
        for _ in 0..<1000 where box.request == nil { await Task.yield() }
        return (box, task)
    }

    @Test("passes a request id to the opener and resolves with the delivered value")
    func delivers() async throws {
        let routes = RouteResults()
        let (box, result) = await open(routes, NewContainerResult.self)
        let request = try #require(box.request)
        #expect(!request.id.isEmpty)
        let created = NewContainerResult(containerId: "c1", name: nil, shortCode: "BOX-2222", visualType: .box, spaceId: "s1")
        #expect(routes.deliver(request, created))
        #expect(try await result.value == created)
    }

    @Test("resolves only once")
    func once() async throws {
        let routes = RouteResults()
        let (box, result) = await open(routes, Int.self)
        #expect(routes.deliver(box.request, 1))
        #expect(!routes.deliver(box.request, 2))
        #expect(try await result.value == 1)
    }

    @Test("resolves undefined when abandoned, and ignores a delivery after that")
    func abandoned() async throws {
        let routes = RouteResults()
        let (box, result) = await open(routes, Int.self)
        routes.abandon(box.request)
        routes.abandon(box.request)
        #expect(!routes.deliver(box.request, 3))
        #expect(try await result.value == nil)
    }

    @Test("keeps concurrent requests apart")
    func concurrent() async throws {
        let routes = RouteResults()
        let (first, firstResult) = await open(routes, String.self)
        let (second, secondResult) = await open(routes, String.self)
        #expect(first.request != second.request)
        routes.deliver(second.request, "second")
        routes.deliver(first.request, "first")
        #expect(try await firstResult.value == "first")
        #expect(try await secondResult.value == "second")
    }

    @Test("ignores a missing or unknown request id")
    func unknown() {
        let routes = RouteResults()
        #expect(!routes.deliver(RouteRequest<Int>?.none, 1))
        #expect(!routes.deliver(RouteRequest<Int>(id: "nobody"), 1))
        routes.abandon(RouteRequest<Int>?.none)
    }

    @Test("an opener that throws drops its request and rethrows")
    func openThrows() async {
        let routes = RouteResults(makeId: { "fixed" })
        await #expect(throws: EntitiesFailure.self) {
            _ = try await routes.open(Int.self) { _ in throw EntitiesFailure("no route") }
        }
        #expect(!routes.isPending(RouteRequest<Int>(id: "fixed")))
        #expect(!routes.deliver(RouteRequest<Int>(id: "fixed"), 1))
    }

    @Test("a delivery of another type does not answer the request")
    func typeMismatch() async throws {
        let routes = RouteResults(makeId: { "same" })
        let (_, result) = await open(routes, Int.self)
        #expect(!routes.deliver(RouteRequest<String>(id: "same"), "x"))
        #expect(routes.deliver(RouteRequest<Int>(id: "same"), 4))
        #expect(try await result.value == 4)
    }
}
